package com.checkkaka.health_workout_export;

import static org.junit.Assert.*;
import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.Comparator;
import org.junit.Test;

public class NativeSyncFilesTest {
    @Test public void atomicRoundTripAndDeleteUseOwnerOnlyFiles() throws Exception {
        Path root = Files.createTempDirectory("native-sync-test-");
        try {
            File file = root.resolve("auto-sync-batch.json").toFile();
            NativeSyncFiles.write(file, "{}".getBytes(), 1024);
            NativeSyncFiles.write(file, "{\"phase\":\"uploading\"}".getBytes(), 1024);
            assertArrayEquals("{\"phase\":\"uploading\"}".getBytes(), NativeSyncFiles.read(file, 1024));
            assertEquals(PosixFilePermissions.fromString("rw-------"), Files.getPosixFilePermissions(file.toPath()));
            assertEquals(1, root.toFile().list().length);
            NativeSyncFiles.delete(file);
            NativeSyncFiles.delete(file);
            assertThrows(java.io.FileNotFoundException.class, () -> NativeSyncFiles.read(file, 1024));
        } finally { removeTree(root); }
    }

    @Test public void oversizedWriteNeverDamagesPriorFile() throws Exception {
        Path root = Files.createTempDirectory("native-sync-test-");
        try {
            File file = root.resolve("sync_state.json").toFile();
            NativeSyncFiles.write(file, "{}".getBytes(), 16);
            assertThrows(NativeSyncFiles.TooLargeException.class, () -> NativeSyncFiles.write(file, new byte[17], 16));
            assertArrayEquals("{}".getBytes(), NativeSyncFiles.read(file, 16));
            assertThrows(NativeSyncFiles.TooLargeException.class, () -> NativeSyncFiles.read(file, 1));
            assertThrows(IOException.class, () -> NativeSyncFiles.write(file, new byte[0], 16));
        } finally { removeTree(root); }
    }

    @Test public void symlinkDestinationAndParentAreRejected() throws Exception {
        Path root = Files.createTempDirectory("native-sync-test-");
        try {
            Path real = root.resolve("real"); Files.createDirectory(real);
            Path link = root.resolve("link"); Files.createSymbolicLink(link, real);
            assertThrows(IOException.class, () -> NativeSyncFiles.write(link.resolve("state.json").toFile(), "{}".getBytes(), 16));
            Path target = root.resolve("target.json"); Files.write(target, "{}".getBytes());
            Path fileLink = root.resolve("state.json"); Files.createSymbolicLink(fileLink, target);
            assertThrows(IOException.class, () -> NativeSyncFiles.write(fileLink.toFile(), "{}".getBytes(), 16));
            assertThrows(IOException.class, () -> NativeSyncFiles.read(fileLink.toFile(), 16));
        } finally { removeTree(root); }
    }

    @Test public void healthPreparedDoesNotOverwriteUploadedFit() throws Exception {
        Path root = Files.createTempDirectory("health-prepared-test-");
        try {
            String fingerprint = "a".repeat(64);
            File uploaded = root.resolve("synced_fits/" + fingerprint + ".fit").toFile();
            File health = NativeSyncFiles.healthPreparedFile(root.toFile(), fingerprint);
            NativeSyncFiles.write(uploaded, new byte[]{1,2,3}, NativeSyncFiles.MAX_FIT_BYTES);
            NativeSyncFiles.write(health, new byte[]{8,9}, NativeSyncFiles.MAX_FIT_BYTES);
            assertArrayEquals(new byte[]{1,2,3}, NativeSyncFiles.read(uploaded, NativeSyncFiles.MAX_FIT_BYTES));
            assertEquals("health_prepared", health.getParentFile().getName());
            NativeSyncFiles.delete(health);
            assertTrue(uploaded.exists());
        } finally { removeTree(root); }
    }

    private static void removeTree(Path root) throws IOException {
        try (java.util.stream.Stream<Path> paths = Files.walk(root)) {
            for (Path path : paths.sorted(Comparator.reverseOrder()).toArray(Path[]::new)) Files.deleteIfExists(path);
        }
    }
}
