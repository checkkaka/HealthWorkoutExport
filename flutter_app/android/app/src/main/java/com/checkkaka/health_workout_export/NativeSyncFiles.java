package com.checkkaka.health_workout_export;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.PosixFilePermissions;

/** Bounded app-private storage. Never falls back to truncating an existing destination. */
public final class NativeSyncFiles {
    public static final int MAX_JSON_BYTES = 4 * 1024 * 1024;
    public static final int MAX_STATE_BYTES = 16 * 1024 * 1024;
    public static final int MAX_RECOVERY_BYTES = 90 * 1024 * 1024;
    public static final int MAX_FIT_BYTES = 64 * 1024 * 1024;
    private NativeSyncFiles() {}

    public static byte[] read(File file, int maximumBytes) throws IOException {
        rejectSymlink(file.toPath());
        if (!file.exists()) throw new FileNotFoundException("Missing sync file");
        if (file.length() > maximumBytes) throw new TooLargeException();
        try (FileInputStream input = new FileInputStream(file); ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192]; int size;
            while ((size = input.read(buffer)) != -1) {
                if (output.size() + size > maximumBytes) throw new TooLargeException();
                output.write(buffer, 0, size);
            }
            return output.toByteArray();
        }
    }

    public static synchronized void write(File file, byte[] bytes, int maximumBytes) throws IOException {
        if (bytes == null || bytes.length == 0) throw new IOException("Empty sync file");
        if (bytes.length > maximumBytes) throw new TooLargeException();
        Path destination = file.toPath();
        Path parent = destination.getParent();
        if (parent == null) throw new IOException("Missing sync directory");
        rejectSymlink(destination);
        rejectSymlink(parent);
        Files.createDirectories(parent);
        ownerOnly(parent, true);
        Path temporary = Files.createTempFile(parent, ".sync-", ".tmp");
        try {
            ownerOnly(temporary, false);
            try (FileOutputStream output = new FileOutputStream(temporary.toFile())) {
                output.write(bytes);
                output.getFD().sync();
            }
            // A failure keeps the old file intact. No delete-first or direct-write fallback.
            Files.move(temporary, destination, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            try (FileChannel directory = FileChannel.open(parent, StandardOpenOption.READ)) { directory.force(true); }
        } finally { Files.deleteIfExists(temporary); }
    }

    public static synchronized void delete(File file) throws IOException {
        rejectSymlink(file.toPath());
        Files.deleteIfExists(file.toPath());
    }

    private static void rejectSymlink(Path path) throws IOException {
        if (Files.isSymbolicLink(path)) throw new IOException("Symlink sync paths are not allowed");
    }

    private static void ownerOnly(Path path, boolean directory) throws IOException {
        try {
            Files.setPosixFilePermissions(path, PosixFilePermissions.fromString(directory ? "rwx------" : "rw-------"));
        } catch (UnsupportedOperationException error) {
            File file = path.toFile();
            if (!file.setReadable(false, false) || !file.setWritable(false, false) || !file.setExecutable(false, false)
                || !file.setReadable(true, true) || !file.setWritable(true, true)
                || directory && !file.setExecutable(true, true)) throw new IOException("Unable to protect sync file");
        }
    }

    public static final class TooLargeException extends IOException {
        private static final long serialVersionUID = 1L;
        TooLargeException() { super("Sync file exceeds size limit"); }
    }
}
