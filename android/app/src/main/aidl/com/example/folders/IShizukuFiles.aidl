package com.example.folders;

// What ShizukuFileService does for the app, running as the shell user (or
// root) that Shizuku runs as. Paths are absolute. Errors come back as an
// IllegalStateException whose message starts with a ShizukuFileService.E_*
// code and a "|".
interface IShizukuFiles {
    // Shizuku calls this when it stops the service.
    void destroy() = 16777114;

    // The user the service runs as (2000 for shell, 0 for root).
    int uid() = 1;

    // "d" or "f", size, modified (ms since 1970), tab-separated.
    String stat(String path) = 2;

    // The folder's entries, written by a thread into a pipe: see
    // ShizukuFileService.writeListing for the format.
    ParcelFileDescriptor list(String path) = 3;

    ParcelFileDescriptor openRead(String path) = 4;

    // Creates the file (truncating it when overwrite is true).
    ParcelFileDescriptor openWrite(String path, boolean overwrite) = 5;

    void mkdir(String path) = 6;

    // A file, or a folder with everything in it. Links are removed, never followed.
    void delete(String path) = 7;

    void rename(String from, String to) = 8;
}
