// Zinbox Helper: Chromium's renderer, GPU and utility processes.
//
// In renderer processes it injects Zinbox's page scripts (the Notification
// bridge and the unread counter) into each new JavaScript context, before the
// page's own scripts run, and forwards their messages to the app.

#include <map>
#include <string>

#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

namespace {

/// window.__zinboxNative(json): hands a message to the app.
class Native : public CefV8Handler {
   public:
    bool Execute(const CefString &name, CefRefPtr<CefV8Value> object, const CefV8ValueList &arguments,
                 CefRefPtr<CefV8Value> &retval, CefString &exception) override {
        if (arguments.empty() || !arguments[0]->IsString()) return true;
        CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext();
        CefRefPtr<CefFrame> frame = context ? context->GetFrame() : nullptr;
        if (!frame) return true;
        CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create("zinbox");
        message->GetArgumentList()->SetString(0, arguments[0]->GetStringValue());
        frame->SendProcessMessage(PID_BROWSER, message);
        return true;
    }

   private:
    IMPLEMENT_REFCOUNTING(Native);
};

class HelperApp : public CefApp, public CefRenderProcessHandler {
   public:
    CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }

    void OnBrowserCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDictionaryValue> extra_info) override {
        if (!extra_info) return;
        scripts_[browser->GetIdentifier()] = {extra_info->GetString("page"), extra_info->GetString("main")};
    }

    void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override { scripts_.erase(browser->GetIdentifier()); }

    void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                          CefRefPtr<CefV8Context> context) override {
        auto found = scripts_.find(browser->GetIdentifier());
        if (found == scripts_.end()) return;
        context->GetGlobal()->SetValue(
            "__zinboxNative", CefV8Value::CreateFunction("__zinboxNative", new Native()),
            static_cast<cef_v8_propertyattribute_t>(V8_PROPERTY_ATTRIBUTE_READONLY | V8_PROPERTY_ATTRIBUTE_DONTENUM |
                                                    V8_PROPERTY_ATTRIBUTE_DONTDELETE));
        CefRefPtr<CefV8Value> result;
        CefRefPtr<CefV8Exception> error;
        context->Eval(found->second.first, "zinbox://page", 0, result, error);
        if (frame->IsMain()) context->Eval(found->second.second, "zinbox://main", 0, result, error);
    }

   private:
    std::map<int, std::pair<CefString, CefString>> scripts_;
    IMPLEMENT_REFCOUNTING(HelperApp);
};

}  // namespace

int main(int argc, char *argv[]) {
    CefScopedSandboxContext sandbox;
    if (!sandbox.Initialize(argc, argv)) return 1;
    CefScopedLibraryLoader loader;
    if (!loader.LoadInHelper()) return 1;
    CefMainArgs args(argc, argv);
    return CefExecuteProcess(args, new HelperApp(), nullptr);
}
