#ifndef RUNNER_DROP_FILES_H_
#define RUNNER_DROP_FILES_H_

#include <windows.h>

#include <string>
#include <vector>

// The drag and drop plugin reads a drag's file list when it enters the window
// and keeps that list, but some sources only give the real one on the drop:
// until then WinRAR names the files inside the archive, and it extracts them
// when asked at the drop. So a thin wrapper around the plugin's drop target
// reads the list again then.

// Wraps the drop target registered on |view|. False if it has none yet.
bool WrapDropTarget(HWND view);

// The files of the last drop (UTF-8); empty if it had none.
std::vector<std::string> LastDroppedFiles();

#endif  // RUNNER_DROP_FILES_H_
