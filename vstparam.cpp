// VST3 host: read + write parameters, and save/load controller state (presets).
// Based on the SDK's PlugProvider reference (component + controller + IConnectionPoint).
//
// Build: g++ -std=c++17 -O2 vstparam.cpp -o vstparam -ldl
//
// Usage:
//   vstparam dump [<path>]                       # list all controller parameters
//   vstparam find [<path>] <substring>           # list params whose title contains substring
//   vstparam set  [<path>] <paramID> <norm0..1>  # set a parameter (hex or decimal ID)
//   vstparam save [<path>] <presetfile>          # save controller state as a preset file
//   vstparam load  [<path>] <presetfile>         # load controller state from a preset file
//
// Default path: ~/.vst3/Discovery.vst3
//
// Notes:
//  * "pad" vs "lead" parameter values are sound-design knowledge you supply.
//    This tool lets you read every parameter, set any of them, and save the
//    resulting controller state as a preset file you can reload.
//  * preset file = raw bytes of the controller's getState() IBStream.

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <string>
#include <vector>
#include <filesystem>
#include <cstdint>
#include <fstream>
#include <sstream>

#include "pluginterfaces/base/funknown.h"
#include "pluginterfaces/base/fplatform.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/base/ftypes.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivsthostapplication.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/vsttypes.h"

using namespace Steinberg;
using namespace Steinberg::Vst;
namespace fs = std::filesystem;

static std::string u16_to_utf8(const char16* s) {
    std::string out;
    if (!s) return out;
    for (int i = 0; i < 128 && s[i]; ++i) {
        char16 c = s[i];
        if (c < 0x80) out.push_back((char)c);
        else if (c < 0x800) { out.push_back((char)(0xC0 | (c >> 6))); out.push_back((char)(0x80 | (c & 0x3F))); }
        else { out.push_back((char)(0xE0 | (c >> 12))); out.push_back((char)(0x80 | ((c >> 6) & 0x3F))); out.push_back((char)(0x80 | (c & 0x3F))); }
    }
    return out;
}

static const TUID& kIEditControllerIid   = Steinberg::Vst::IEditController_iid;
static const TUID& kIComponentIid        = Steinberg::Vst::IComponent_iid;
static const TUID& kIHostAppIid          = Steinberg::Vst::IHostApplication_iid;
static const TUID& kICompHandlerIid      = Steinberg::Vst::IComponentHandler_iid;
static const TUID& kIConnectionPointIid  = Steinberg::Vst::IConnectionPoint_iid;

//-----------------------------------------------------------------------------
struct Host : public IHostApplication, public IComponentHandler {
    int32 ref = 1;
    tresult PLUGIN_API queryInterface(const TUID iid, void** obj) SMTG_OVERRIDE {
        if (!obj) return kInvalidArgument;
        if (memcmp(iid, kIHostAppIid, sizeof(TUID)) == 0) { *obj = (IHostApplication*)this; addRef(); return kResultOk; }
        if (memcmp(iid, kICompHandlerIid, sizeof(TUID)) == 0) { *obj = (IComponentHandler*)this; addRef(); return kResultOk; }
        *obj = nullptr; return kNoInterface;
    }
    uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return ++ref; }
    uint32 PLUGIN_API release() SMTG_OVERRIDE { return --ref; }
    tresult PLUGIN_API getName(String128 n) SMTG_OVERRIDE { strncpy8((char8*)n, "vstparam", 128); return kResultOk; }
    tresult PLUGIN_API createInstance(TUID, TUID, void**) SMTG_OVERRIDE { return kNotImplemented; }
    tresult PLUGIN_API beginEdit(ParamID) SMTG_OVERRIDE { return kResultOk; }
    tresult PLUGIN_API performEdit(ParamID, ParamValue) SMTG_OVERRIDE { return kResultOk; }
    tresult PLUGIN_API endEdit(ParamID) SMTG_OVERRIDE { return kResultOk; }
    tresult PLUGIN_API restartComponent(int32) SMTG_OVERRIDE { return kResultOk; }
};

//-----------------------------------------------------------------------------
static IPluginFactory* load_factory(const std::string& input, std::string& soPath) {
    std::string path = input;
    if (path[0] == '~') { const char* h = getenv("HOME"); path = (h ? h : "") + path.substr(1); }
    fs::path p(path); std::string sp;
    if (fs::is_directory(p)) {
        fs::path c = p / "Contents" / "x86_64-linux";
        if (!fs::is_directory(c)) return nullptr;
        for (auto& e : fs::directory_iterator(c)) if (e.is_regular_file() && e.path().extension() == ".so") { sp = e.path().string(); break; }
    } else sp = path;
    if (sp.empty()) return nullptr;
    soPath = sp;
    void* h = dlopen(sp.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!h) return nullptr;
    auto GPF = (IPluginFactory*(*)())dlsym(h, "GetPluginFactory");
    return GPF ? GPF() : nullptr;
}

static int find_class(IPluginFactory* f, PClassInfo& out, const char* catNeedle) {
    int32 n = f->countClasses();
    for (int32 i = 0; i < n; ++i) {
        PClassInfo ci;
        if (f->getClassInfo(i, &ci) != kResultOk) continue;
        if (strstr(ci.category, catNeedle)) { out = ci; return i; }
    }
    return -1;
}

//-----------------------------------------------------------------------------
// Connect component<->controller per the SDK PlugProvider reference,
// then init the controller. Returns controller (or nullptr).
//-----------------------------------------------------------------------------
static IEditController* open_plugin(const std::string& input, Host& host, IComponent*& compOut) {
    compOut = nullptr;
    std::string soPath;
    IPluginFactory* f = load_factory(input, soPath);
    if (!f) { fprintf(stderr, "no factory in %s\n", input.c_str()); return nullptr; }

    PClassInfo compInfo, ctrlInfo;
    int ci = find_class(f, compInfo, "Audio Module");
    int ti = find_class(f, ctrlInfo, "Controller");

    IComponent* comp = nullptr;
    IEditController* ctrl = nullptr;
    TUID controllerCID = {}; bool haveCID = false;

    if (ci >= 0 && f->createInstance((const char8*)compInfo.cid, (const char8*)kIComponentIid, (void**)&comp) == kResultOk && comp) {
        comp->initialize(static_cast<IHostApplication*>(&host));
        comp->setActive(true);
        compOut = comp;
        if (comp->getControllerClassId(controllerCID) == kResultTrue) haveCID = true;
    }
    if (ti >= 0) {
        const char8* useCID = haveCID ? (const char8*)controllerCID : (const char8*)ctrlInfo.cid;
        if (f->createInstance(useCID, (const char8*)kIEditControllerIid, (void**)&ctrl) == kResultOk && ctrl) {
            ctrl->initialize(static_cast<IHostApplication*>(&host));
            ctrl->setComponentHandler(static_cast<IComponentHandler*>(&host));
        }
    }
    if (comp && ctrl) {
        IConnectionPoint* compCP = nullptr; IConnectionPoint* ctrlCP = nullptr;
        if (comp->queryInterface(kIConnectionPointIid, (void**)&compCP) == kResultOk &&
            ctrl->queryInterface(kIConnectionPointIid, (void**)&ctrlCP) == kResultOk) {
            compCP->connect(ctrlCP);
            ctrlCP->connect(compCP);
        }
        if (compCP) compCP->release();
        if (ctrlCP) ctrlCP->release();
    }
    return ctrl;
}

//-----------------------------------------------------------------------------
static void list_params(IEditController* ctrl, const char* filter) {
    int32 count = ctrl->getParameterCount();
    int32 shown = 0;
    for (int32 i = 0; i < count; ++i) {
        ParameterInfo pi;
        if (ctrl->getParameterInfo(i, pi) != kResultOk) continue;
        std::string title = u16_to_utf8(pi.title);
        if (filter && title.find(filter) == std::string::npos) continue;
        ParamValue plain = ctrl->normalizedParamToPlain(pi.id, pi.defaultNormalizedValue);
        printf("  [%3d] id=0x%-6X %-40s def=%.4f plain=%.4f steps=%-4d units='%s'\n",
               i, (unsigned)pi.id, title.c_str(), pi.defaultNormalizedValue, plain, pi.stepCount, u16_to_utf8(pi.units).c_str());
        shown++;
    }
    printf("total: %d (shown %d)\n", count, shown);
}

//-----------------------------------------------------------------------------
int main(int argc, char** argv) {
    std::string cmd   = (argc > 1) ? argv[1] : "dump";
    std::string input = (argc > 2) ? argv[2] : std::string("~/.vst3/Discovery.vst3");

    Host host;
    IComponent* comp = nullptr;
    IEditController* ctrl = open_plugin(input, host, comp);
    if (!ctrl) return 1;

    if (cmd == "dump") {
        list_params(ctrl, nullptr);
    }
    else if (cmd == "find") {
        if (argc < 4) { fprintf(stderr, "usage: vstparam find <path> <substring>\n"); ctrl->terminate(); ctrl->release(); if (comp) { comp->setActive(false); comp->terminate(); comp->release(); } return 1; }
        list_params(ctrl, argv[3]);
    }
    else if (cmd == "set") {
        if (argc < 5) { fprintf(stderr, "usage: vstparam set <path> <paramID> <normValue 0..1>\n"); ctrl->terminate(); ctrl->release(); if (comp) { comp->setActive(false); comp->terminate(); comp->release(); } return 1; }
        ParamID id = (ParamID)strtoul(argv[3], nullptr, 0);
        double val = atof(argv[4]);
        ctrl->setParamNormalized(id, (ParamValue)val);
        ParamValue rb = ctrl->getParamNormalized(id);
        printf("set param 0x%X -> %.4f (readback %.4f)\n", (unsigned)id, val, rb);
    }
    else if (cmd == "save") {
        if (argc < 4) { fprintf(stderr, "usage: vstparam save <path> <presetfile>\n"); ctrl->terminate(); ctrl->release(); if (comp) { comp->setActive(false); comp->terminate(); comp->release(); } return 1; }
        int32 count = ctrl->getParameterCount();
        std::ofstream out(argv[3]);
        if (!out) { fprintf(stderr, "cannot write %s\n", argv[3]); ctrl->terminate(); ctrl->release(); if (comp) { comp->setActive(false); comp->terminate(); comp->release(); } return 1; }
        out << "# VST3 parameter preset snapshot\n# format: <paramID decimal> <normalizedValue 0..1>\n";
        int32 saved = 0;
        for (int32 i = 0; i < count; ++i) {
            ParameterInfo pi;
            if (ctrl->getParameterInfo(i, pi) != kResultOk) continue;
            if (pi.flags & ParameterInfo::kIsHidden) continue;
            double v = (double)ctrl->getParamNormalized(pi.id);
            out << (unsigned)pi.id << " " << v << "\n";
            saved++;
        }
        out.close();
        printf("saved snapshot of %d parameters to %s\n", saved, argv[3]);
    }
    else if (cmd == "load") {
        if (argc < 4) { fprintf(stderr, "usage: vstparam load <path> <presetfile>\n"); ctrl->terminate(); ctrl->release(); if (comp) { comp->setActive(false); comp->terminate(); comp->release(); } return 1; }
        std::ifstream in(argv[3]);
        if (!in) { fprintf(stderr, "cannot open %s\n", argv[3]); ctrl->terminate(); ctrl->release(); if (comp) { comp->setActive(false); comp->terminate(); comp->release(); } return 1; }
        int32 loaded = 0;
        std::string line;
        while (std::getline(in, line)) {
            if (line.empty() || line[0] == '#') continue;
            std::istringstream iss(line);
            unsigned id; double val;
            if (iss >> id >> val) {
                ctrl->setParamNormalized((ParamID)id, (ParamValue)val);
                loaded++;
            }
        }
        printf("loaded %d parameters from %s\n", loaded, argv[3]);
    }
    else {
        fprintf(stderr, "unknown command: %s (dump|find|set|save|load)\n", cmd.c_str());
    }

    ctrl->terminate();
    ctrl->release();
    if (comp) { comp->setActive(false); comp->terminate(); comp->release(); }
    return 0;
}
