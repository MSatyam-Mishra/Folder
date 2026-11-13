package com.example.folders

import android.content.Context
import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import java.io.DataOutputStream
import java.io.File
import kotlin.system.exitProcess

/**
 * Files for the app in Shizuku's own process, which runs as the shell user
 * (started with adb or wireless debugging) or root. Android 11 and newer lock
 * Android/data and Android/obb for apps, even with All files access, but the
 * shell user may still open them.
 *
 * Shizuku starts it with app_process from this APK and calls one of its
 * constructors by reflection, so release builds keep them (proguard-rules.pro).
 * Every call checks its path and fails with an IllegalStateException whose
 * message starts with one of the E_* codes and a `|` (binder carries that
 * exception and its message across; ServiceSpecificException isn't in the
 * SDK), which [ShizukuNative] turns into plain words.
 */
class ShizukuFileService() : IShizukuFiles.Stub() {
    @Suppress("unused", "UNUSED_PARAMETER")
    constructor(context: Context) : this()

    override fun destroy() {
        exitProcess(0)
    }

    override fun uid(): Int = Os.getuid()

    override fun stat(path: String): String {
        val st = statOf(path)
        return "${if (isDir(st)) "d" else "f"}\t${if (isDir(st)) 0 else st.st_size}\t${st.st_mtime * 1000}"
    }

    override fun list(path: String): ParcelFileDescriptor {
        val st = statOf(path)
        if (!isDir(st)) fail(E_NOT_FOUND, "Not a folder: $path")
        val names = File(path).list() ?: fail(E_PERMISSION, "Can't open the folder $path")
        val (read, write) = ParcelFileDescriptor.createPipe()
        Thread {
            try {
                DataOutputStream(ParcelFileDescriptor.AutoCloseOutputStream(write).buffered()).use {
                    writeListing(path, names, it)
                }
            } catch (e: Exception) {
                // The app stopped reading.
            }
        }.start()
        return read
    }

    /**
     * For each entry, a 1 byte, its name (writeUTF), whether it's a folder,
     * its size and when it changed (ms); a 0 byte at the end. An entry that
     * vanishes meanwhile is left out; one whose details can't be read is a file
     * of size 0.
     */
    private fun writeListing(folder: String, names: Array<String>, out: DataOutputStream) {
        for (name in names) {
            val st = try {
                Os.stat("$folder/$name")
            } catch (e: ErrnoException) {
                if (e.errno == OsConstants.ENOENT) {
                    // A link to nowhere still shows, as a file.
                    try {
                        Os.lstat("$folder/$name")
                    } catch (e2: ErrnoException) {
                        continue
                    }
                } else {
                    null
                }
            }
            out.writeByte(1)
            out.writeUTF(name)
            val dir = st != null && isDir(st)
            out.writeBoolean(dir)
            out.writeLong(if (st == null || dir) 0 else st.st_size)
            out.writeLong(if (st == null) 0 else st.st_mtime * 1000)
        }
        out.writeByte(0)
    }

    override fun openRead(path: String): ParcelFileDescriptor {
        val st = statOf(path)
        if (isDir(st)) fail(E_NOT_FOUND, "Not a file: $path")
        return try {
            ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
        } catch (e: Exception) {
            fail(E_PERMISSION, "Can't open $path")
        }
    }

    override fun openWrite(path: String, overwrite: Boolean): ParcelFileDescriptor {
        val existing = statOrNull(path)
        if (existing != null && (isDir(existing) || !overwrite)) fail(E_EXISTS, "Already there: $path")
        val parent = File(path).parent ?: fail(E_NOT_FOUND, "No folder for $path")
        val parentSt = statOrNull(parent) ?: fail(E_NOT_FOUND, "No folder $parent")
        if (!isDir(parentSt)) fail(E_NOT_FOUND, "Not a folder: $parent")
        val mode = ParcelFileDescriptor.MODE_WRITE_ONLY or
            ParcelFileDescriptor.MODE_CREATE or
            ParcelFileDescriptor.MODE_TRUNCATE
        return try {
            ParcelFileDescriptor.open(File(path), mode)
        } catch (e: Exception) {
            fail(E_PERMISSION, "Can't write $path")
        }
    }

    override fun mkdir(path: String) {
        errno(path) { Os.mkdir(path, "771".toInt(8)) }
    }

    override fun delete(path: String) {
        val st = try {
            Os.lstat(path)
        } catch (e: ErrnoException) {
            throw failure(e, path)
        }
        deleteTree(path, st)
    }

    private fun deleteTree(path: String, st: StructStat) {
        if (OsConstants.S_ISDIR(st.st_mode)) {
            for (name in File(path).list() ?: fail(E_PERMISSION, "Can't open the folder $path")) {
                val child = "$path/$name"
                val childSt = try {
                    Os.lstat(child)
                } catch (e: ErrnoException) {
                    if (e.errno == OsConstants.ENOENT) continue
                    throw failure(e, child)
                }
                deleteTree(child, childSt)
            }
            // remove(3) takes empty folders too.
            errno(path) { Os.remove(path) }
        } else {
            // Files and links alike: a link goes, never what it points to.
            errno(path) { Os.remove(path) }
        }
    }

    override fun rename(from: String, to: String) {
        statOf(from)
        // Os.rename would replace a file there without asking.
        if (statOrNull(to, follow = false) != null) fail(E_EXISTS, "Already there: $to")
        errno(from) { Os.rename(from, to) }
    }

    private fun isDir(st: StructStat) = OsConstants.S_ISDIR(st.st_mode)

    private fun statOf(path: String): StructStat = try {
        Os.stat(path)
    } catch (e: ErrnoException) {
        throw failure(e, path)
    }

    private fun statOrNull(path: String, follow: Boolean = true): StructStat? = try {
        if (follow) Os.stat(path) else Os.lstat(path)
    } catch (e: ErrnoException) {
        null
    }

    private inline fun errno(path: String, block: () -> Unit) {
        try {
            block()
        } catch (e: ErrnoException) {
            throw failure(e, path)
        }
    }

    private fun failure(e: ErrnoException, path: String): IllegalStateException {
        val code = when (e.errno) {
            OsConstants.ENOENT, OsConstants.ENOTDIR -> E_NOT_FOUND
            OsConstants.EEXIST, OsConstants.ENOTEMPTY -> E_EXISTS
            OsConstants.EACCES, OsConstants.EPERM, OsConstants.EROFS -> E_PERMISSION
            OsConstants.EXDEV -> E_UNSUPPORTED
            else -> E_OTHER
        }
        return IllegalStateException("$code|${e.message}: $path")
    }

    private fun fail(code: Int, message: String): Nothing = throw IllegalStateException("$code|$message")

    companion object {
        const val E_NOT_FOUND = 1
        const val E_EXISTS = 2
        const val E_PERMISSION = 3
        const val E_UNSUPPORTED = 4
        const val E_OTHER = 5
    }
}
