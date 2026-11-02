#include "drop_files.h"

#include <oleidl.h>
#include <shellapi.h>

#include "utils.h"

namespace {

std::vector<std::string> g_last_drop;
IDropTarget* g_wrapper = nullptr;

std::vector<std::string> ReadFiles(IDataObject* data) {
  std::vector<std::string> files;
  FORMATETC format = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  STGMEDIUM medium = {};
  if (FAILED(data->GetData(&format, &medium))) return files;
  if (medium.tymed == TYMED_HGLOBAL) {
    HDROP drop = static_cast<HDROP>(medium.hGlobal);
    const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    for (UINT i = 0; i < count; i++) {
      const UINT length = DragQueryFileW(drop, i, nullptr, 0);
      std::wstring path(length, L'\0');
      DragQueryFileW(drop, i, path.data(), length + 1);
      files.push_back(Utf8FromUtf16(path.c_str()));
    }
  }
  ReleaseStgMedium(&medium);
  return files;
}

// Passes everything on to the plugin's target.
class WrappedDropTarget : public IDropTarget {
 public:
  explicit WrappedDropTarget(IDropTarget* target) : target_(target) {
    target_->AddRef();
  }

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
    if (id == IID_IUnknown || id == IID_IDropTarget) {
      *out = static_cast<IDropTarget*>(this);
      AddRef();
      return S_OK;
    }
    *out = nullptr;
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(InterlockedIncrement(&references_));
  }

  ULONG STDMETHODCALLTYPE Release() override {
    const LONG left = InterlockedDecrement(&references_);
    if (left == 0) delete this;
    return static_cast<ULONG>(left);
  }

  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD keys,
                                      POINTL point, DWORD* effect) override {
    g_last_drop.clear();
    return target_->DragEnter(data, keys, point, effect);
  }

  HRESULT STDMETHODCALLTYPE DragOver(DWORD keys, POINTL point,
                                     DWORD* effect) override {
    return target_->DragOver(keys, point, effect);
  }

  HRESULT STDMETHODCALLTYPE DragLeave() override {
    return target_->DragLeave();
  }

  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD keys, POINTL point,
                                 DWORD* effect) override {
    g_last_drop = ReadFiles(data);
    return target_->Drop(data, keys, point, effect);
  }

 private:
  ~WrappedDropTarget() { target_->Release(); }

  IDropTarget* target_;
  LONG references_ = 1;
};

}  // namespace

bool WrapDropTarget(HWND view) {
  auto* target =
      static_cast<IDropTarget*>(GetPropW(view, L"OleDropTargetInterface"));
  if (!target) return false;
  if (target == g_wrapper) return true;
  // It holds on to the plugin's target while that's taken off the window.
  auto* wrapper = new WrappedDropTarget(target);
  RevokeDragDrop(view);
  const bool wrapped = SUCCEEDED(RegisterDragDrop(view, wrapper));
  if (wrapped) {
    g_wrapper = wrapper;
  } else {
    RegisterDragDrop(view, target);
  }
  wrapper->Release();
  return wrapped;
}

std::vector<std::string> LastDroppedFiles() { return g_last_drop; }
