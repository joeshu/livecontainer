#import "unarchive.h"

#include "archive.h"
#include "archive_entry.h"
#include <sys/stat.h>
#include <stdint.h>

static const la_int64_t LCMaxArchiveEntries = 100000;
static const la_int64_t LCMaxArchiveFileSize = 1024LL * 1024LL * 1024LL;
static const la_int64_t LCMaxArchiveTotalSize = 2LL * 1024LL * 1024LL * 1024LL;
static const NSUInteger LCMaxArchivePathLength = 4096;
static const NSUInteger LCMaxArchivePathDepth = 64;

static BOOL LCValidateArchivePath(const char *pathname, NSString **normalizedPath) {
    if (pathname == NULL || pathname[0] == '\0') {
        return NO;
    }

    NSString *rawPath = [[NSString alloc] initWithUTF8String:pathname];
    if (rawPath == nil || rawPath.length == 0 || rawPath.length > LCMaxArchivePathLength ||
        [rawPath hasPrefix:@"/"] || [rawPath containsString:@"\\"]) {
        return NO;
    }

    NSArray<NSString *> *components = [rawPath pathComponents];
    if (components.count == 0 || components.count > LCMaxArchivePathDepth) {
        return NO;
    }

    for (NSString *component in components) {
        if (component.length == 0 || [component isEqualToString:@"."] ||
            [component isEqualToString:@".."] || [component isEqualToString:@"/"]) {
            return NO;
        }
    }

    NSString *safePath = [components componentsJoinedByString:@"/"];
    if (safePath.length == 0 || [safePath hasPrefix:@"/"] ||
        [safePath containsString:@"../"]) {
        return NO;
    }
    if (normalizedPath != NULL) {
        *normalizedPath = safePath;
    }
    return YES;
}

static BOOL LCValidateArchiveEntry(struct archive_entry *entry, NSString **safePath,
                                   la_int64_t *regularFileSize) {
    if (entry == NULL || !LCValidateArchivePath(archive_entry_pathname(entry), safePath)) {
        return NO;
    }
    if (archive_entry_symlink(entry) != NULL || archive_entry_hardlink(entry) != NULL) {
        return NO;
    }

    mode_t fileType = archive_entry_filetype(entry);
    if (fileType != AE_IFREG && fileType != AE_IFDIR) {
        return NO;
    }

    la_int64_t size = archive_entry_size(entry);
    if (fileType == AE_IFREG) {
        if (size < 0 || size > LCMaxArchiveFileSize) {
            return NO;
        }
        if (regularFileSize != NULL) {
            *regularFileSize = size;
        }
    } else if (regularFileSize != NULL) {
        *regularFileSize = 0;
    }
    return YES;
}

static int LCCopyData(struct archive *reader, struct archive *writer,
                      NSProgress *progress, la_int64_t expectedSize) {
    const void *buffer = NULL;
    size_t size = 0;
    la_int64_t offset = 0;
    la_int64_t copied = 0;

    for (;;) {
        int result = archive_read_data_block(reader, &buffer, &size, &offset);
        if (result == ARCHIVE_EOF) {
            return copied == expectedSize ? ARCHIVE_OK : ARCHIVE_FATAL;
        }
        // Reject sparse/non-contiguous data. IPA payloads do not need it, and
        // rejecting it makes the byte accounting and resource limit exact.
        if (result < ARCHIVE_OK || offset != copied ||
            (la_int64_t)size > expectedSize - copied) {
            return ARCHIVE_FATAL;
        }

        result = archive_write_data_block(writer, buffer, size, offset);
        if (result < ARCHIVE_OK) {
            return result;
        }
        copied += (la_int64_t)size;
        progress.completedUnitCount += (int64_t)size;
    }
}

static void LCCloseArchives(struct archive *reader, struct archive *writer) {
    if (reader != NULL) {
        archive_read_close(reader);
        archive_read_free(reader);
    }
    if (writer != NULL) {
        archive_write_close(writer);
        archive_write_free(writer);
    }
}

int extract(NSString *fileToExtract, NSString *extractionPath, NSProgress *progress) {
    if (fileToExtract == nil || extractionPath == nil || progress == nil) {
        return ARCHIVE_FATAL;
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:fileToExtract.path isDirectory:&isDirectory] || isDirectory) {
        return ARCHIVE_FATAL;
    }
    if (![fileManager fileExistsAtPath:extractionPath.path isDirectory:&isDirectory]) {
        NSError *error = nil;
        if (![fileManager createDirectoryAtPath:extractionPath.path
                    withIntermediateDirectories:YES attributes:nil error:&error]) {
            return ARCHIVE_FATAL;
        }
    }
    if (!isDirectory) {
        return ARCHIVE_FATAL;
    }

    struct archive *reader = archive_read_new();
    if (reader == NULL) {
        return ARCHIVE_FATAL;
    }
    archive_read_support_format_all(reader);
    archive_read_support_filter_all(reader);
    int result = archive_read_open_filename(reader, fileToExtract.fileSystemRepresentation, 10240);
    if (result != ARCHIVE_OK) {
        archive_read_free(reader);
        return result;
    }

    la_int64_t totalSize = 0;
    la_int64_t entryCount = 0;
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet setWithCapacity:1024];
    struct archive_entry *entry = NULL;
    while ((result = archive_read_next_header(reader, &entry)) != ARCHIVE_EOF) {
        if (result < ARCHIVE_OK) {
            LCCloseArchives(reader, NULL);
            return result;
        }
        if (++entryCount > LCMaxArchiveEntries) {
            LCCloseArchives(reader, NULL);
            return ARCHIVE_FATAL;
        }

        NSString *safePath = nil;
        la_int64_t fileSize = 0;
        if (!LCValidateArchiveEntry(entry, &safePath, &fileSize) ||
            [seenPaths containsObject:safePath] ||
            fileSize > LCMaxArchiveTotalSize - totalSize) {
            LCCloseArchives(reader, NULL);
            return ARCHIVE_FATAL;
        }
        [seenPaths addObject:safePath];
        totalSize += fileSize;
    }
    if (result != ARCHIVE_EOF) {
        LCCloseArchives(reader, NULL);
        return result;
    }
    LCCloseArchives(reader, NULL);

    progress.completedUnitCount = 0;
    progress.totalUnitCount = MAX((int64_t)1, totalSize);

    reader = archive_read_new();
    if (reader == NULL) {
        return ARCHIVE_FATAL;
    }
    archive_read_support_format_all(reader);
    archive_read_support_filter_all(reader);
    result = archive_read_open_filename(reader, fileToExtract.fileSystemRepresentation, 10240);
    if (result != ARCHIVE_OK) {
        archive_read_free(reader);
        return result;
    }

    struct archive *writer = archive_write_disk_new();
    if (writer == NULL) {
        LCCloseArchives(reader, NULL);
        return ARCHIVE_FATAL;
    }
    int flags = ARCHIVE_EXTRACT_SECURE_NODOTDOT |
                ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS |
                ARCHIVE_EXTRACT_SECURE_SYMLINKS |
                ARCHIVE_EXTRACT_SAFE_WRITES;
    archive_write_disk_set_options(writer, flags);
    archive_write_disk_set_standard_lookup(writer);

    NSString *rootPath = extractionPath.stringByStandardizingPath;
    NSString *rootPrefix = [rootPath stringByAppendingString:@"/"];
    while ((result = archive_read_next_header(reader, &entry)) != ARCHIVE_EOF) {
        if (result < ARCHIVE_OK) {
            LCCloseArchives(reader, writer);
            return result;
        }

        NSString *safePath = nil;
        la_int64_t fileSize = 0;
        if (!LCValidateArchiveEntry(entry, &safePath, &fileSize)) {
            LCCloseArchives(reader, writer);
            return ARCHIVE_FATAL;
        }

        NSString *outputPath = [rootPath stringByAppendingPathComponent:safePath];
        NSString *standardizedOutput = outputPath.stringByStandardizingPath;
        if (![standardizedOutput hasPrefix:rootPrefix]) {
            LCCloseArchives(reader, writer);
            return ARCHIVE_FATAL;
        }
        archive_entry_set_pathname(entry, standardizedOutput.fileSystemRepresentation);

        result = archive_write_header(writer, entry);
        if (result < ARCHIVE_OK) {
            LCCloseArchives(reader, writer);
            return result;
        }
        if (fileSize > 0) {
            result = LCCopyData(reader, writer, progress, fileSize);
            if (result < ARCHIVE_OK) {
                LCCloseArchives(reader, writer);
                return result;
            }
        }
        result = archive_write_finish_entry(writer);
        if (result < ARCHIVE_OK) {
            LCCloseArchives(reader, writer);
            return result;
        }
    }

    if (result != ARCHIVE_EOF) {
        LCCloseArchives(reader, writer);
        return result;
    }
    LCCloseArchives(reader, writer);
    return ARCHIVE_OK;
}
