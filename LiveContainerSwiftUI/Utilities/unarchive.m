#import "unarchive.h"

#include "archive.h"
#include "archive_entry.h"
#include <stdlib.h>

static int
copy_data(struct archive *ar, struct archive *aw, NSProgress *progress)
{
  int r;
  const void *buff;
  size_t size;
  la_int64_t offset;

  for (;;) {
    r = archive_read_data_block(ar, &buff, &size, &offset);
    if (r == ARCHIVE_EOF)
      return (ARCHIVE_OK);
    if (r < ARCHIVE_OK)
      return (r);
    r = archive_write_data_block(aw, buff, size, offset);
    if (r < ARCHIVE_OK) {
      fprintf(stderr, "%s\n", archive_error_string(aw));
      return (r);
    }
    progress.completedUnitCount += size;
  }
}

int extract(NSString* fileToExtract, NSString* extractionPath, NSProgress* progress)
{
    struct archive *a;
    struct archive *ext;
    struct archive_entry *entry;
    int flags;
    int r;
    // Foundation may abbreviate /private/var back to /var. libarchive's
    // secure-link mode needs the actual POSIX path, without parent symlinks.
    char *resolvedRoot = realpath(extractionPath.fileSystemRepresentation, NULL);
    if (!resolvedRoot) return 1;
    NSString *root = [NSString stringWithUTF8String:resolvedRoot];
    free(resolvedRoot);
    if (!root.length) return 1;

    /* Select which attributes we want to restore. */
    flags = ARCHIVE_EXTRACT_TIME;
    flags |= ARCHIVE_EXTRACT_PERM;
    flags |= ARCHIVE_EXTRACT_ACL;
    flags |= ARCHIVE_EXTRACT_FFLAGS;
    flags |= ARCHIVE_EXTRACT_SECURE_SYMLINKS;
    flags |= ARCHIVE_EXTRACT_SECURE_NODOTDOT;

    // Calculate decompressed size
    a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    if ((r = archive_read_open_filename(a, fileToExtract.fileSystemRepresentation, 10240))) {
        archive_read_free(a);
        return 1;
    }
    while ((r = archive_read_next_header(a, &entry)) != ARCHIVE_EOF) {
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(a));
        if (r < ARCHIVE_OK) {
            archive_read_close(a);
            archive_read_free(a);
            return 1;
        }
        progress.totalUnitCount += archive_entry_size(entry);
    }
    archive_read_close(a);
    archive_read_free(a);

    // Re-open the archive and extract
    a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    if ((r = archive_read_open_filename(a, fileToExtract.fileSystemRepresentation, 10240))) {
        archive_read_free(a);
        return 1;
    }
    ext = archive_write_disk_new();
    archive_write_disk_set_options(ext, flags);
    archive_write_disk_set_standard_lookup(ext);

    while ((r = archive_read_next_header(a, &entry)) != ARCHIVE_EOF) {
        if (r == ARCHIVE_EOF)
            break;
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(a));
        if (r < ARCHIVE_OK)
            break;
        
        const char *rawPath = archive_entry_pathname(entry);
        NSString *currentFile = rawPath ? [NSString stringWithUTF8String:rawPath] : nil;
        if (!currentFile.length || currentFile.isAbsolutePath ||
            [currentFile.pathComponents containsObject:@".."] || archive_entry_hardlink(entry)) {
            r = ARCHIVE_FATAL;
            break;
        }
        NSString *fullOutputPath = [root stringByAppendingPathComponent:currentFile];
        const char *rawLink = archive_entry_symlink(entry);
        if (rawLink) {
            NSString *target = [NSString stringWithUTF8String:rawLink];
            NSString *resolved = [[fullOutputPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:target ?: @""] stringByStandardizingPath];
            if (!target.length || target.isAbsolutePath ||
                ![resolved hasPrefix:[root stringByAppendingString:@"/"]]) {
                r = ARCHIVE_FATAL;
                break;
            }
        }
        archive_entry_set_pathname(entry, fullOutputPath.fileSystemRepresentation);

        r = archive_write_header(ext, entry);
        if (r < ARCHIVE_OK) {
            fprintf(stderr, "%s\n", archive_error_string(ext));
            break;
        } else if (archive_entry_size(entry) > 0) {
            r = copy_data(a, ext, progress);
            if (r < ARCHIVE_OK)
                fprintf(stderr, "%s\n", archive_error_string(ext));
            if (r < ARCHIVE_OK)
                break;
        }
        r = archive_write_finish_entry(ext);
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(ext));
        if (r < ARCHIVE_OK)
            break;
    }
    BOOL success = (r == ARCHIVE_EOF);
    if (archive_read_close(a) < ARCHIVE_OK) success = NO;
    archive_read_free(a);
    if (archive_write_close(ext) < ARCHIVE_OK) success = NO;
    archive_write_free(ext);

    return success ? 0 : 1;
}
