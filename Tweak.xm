#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <zlib.h>
#import <sys/stat.h>
#import <signal.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>

static NSString *const kIGRRootName = @"IGRestore";
static NSString *const kIGRLogName = @"IGRestore.log";

static NSString *IGRDefaultsPath(void) {
    NSString *path = [[[NSUserDefaults alloc] initWithSuiteName:@"com.bluek.igrestore"] stringForKey:@"Path"];
    return path.length ? path : [@"/var/jb/var/mobile/Documents" stringByAppendingPathComponent:kIGRRootName];
}

static NSString *IGRAppFallbackPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (documents.length == 0) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kIGRRootName];
}

static void IGRLog(NSString *message) {
    @try {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileManager *manager = [NSFileManager defaultManager];
        NSArray *directories = @[IGRDefaultsPath(), IGRAppFallbackPath()];
        for (NSString *directory in directories) {
            [manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *path = [directory stringByAppendingPathComponent:kIGRLogName];
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
            if (handle) {
                [handle seekToEndOfFile];
                [handle writeData:data];
                [handle closeFile];
                break;
            } else if ([data writeToFile:path atomically:NO]) {
                break;
            }
        }
    } @catch (NSException *exception) { }
}

static NSString *IGRFindBackupDirectory(void) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSMutableArray *roots = [NSMutableArray arrayWithObject:IGRDefaultsPath()];
    NSString *fallback = IGRAppFallbackPath();
    if (![roots containsObject:fallback]) [roots addObject:fallback];

    for (NSString *root in roots) {
        NSString *direct = [root stringByAppendingPathComponent:@"com.burbn.instagram.tar.gzip"];
        if ([manager fileExistsAtPath:direct]) return root;
        NSArray *children = [manager contentsOfDirectoryAtPath:root error:nil];
        for (NSString *child in children) {
            NSString *candidate = [root stringByAppendingPathComponent:child];
            BOOL isDirectory = NO;
            if (![manager fileExistsAtPath:candidate isDirectory:&isDirectory] || !isDirectory) continue;
            if ([manager fileExistsAtPath:[candidate stringByAppendingPathComponent:@"com.burbn.instagram.tar.gzip"]]) {
                return candidate;
            }
        }
    }
    return nil;
}

static NSString *IGRStripComponents(NSString *path, NSUInteger count) {
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    NSMutableArray *kept = [NSMutableArray array];
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *part = parts[i];
        if (part.length == 0 || [part isEqualToString:@"."]) continue;
        if ([part isEqualToString:@".."]) return nil;
        if (i < count) continue;
        [kept addObject:part];
    }
    return kept.count ? [kept componentsJoinedByString:@"/"] : nil;
}

static BOOL IGRReadExact(gzFile gz, void *buffer, NSUInteger length) {
    unsigned char *bytes = (unsigned char *)buffer;
    NSUInteger done = 0;
    while (done < length) {
        int readBytes = gzread(gz, bytes + done, (unsigned int)(length - done));
        if (readBytes <= 0) return NO;
        done += (NSUInteger)readBytes;
    }
    return YES;
}

static BOOL IGRSkipBytes(gzFile gz, unsigned long long length) {
    unsigned char buffer[16384];
    while (length > 0) {
        NSUInteger chunk = (NSUInteger)MIN(length, sizeof(buffer));
        if (!IGRReadExact(gz, buffer, chunk)) return NO;
        length -= chunk;
    }
    return YES;
}

static BOOL IGRExtractTarGz(NSString *archive, NSString *destination, NSUInteger strip) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:archive]) {
        IGRLog([NSString stringWithFormat:@"missing archive %@", archive]);
        return NO;
    }
    gzFile gz = gzopen(archive.fileSystemRepresentation, "rb");
    if (!gz) {
        IGRLog([NSString stringWithFormat:@"cannot open %@", archive]);
        return NO;
    }

    NSFileManager *manager = [NSFileManager defaultManager];
    unsigned char header[512];
    NSUInteger extracted = 0;
    BOOL ok = YES;
    while (IGRReadExact(gz, header, sizeof(header))) {
        BOOL empty = YES;
        for (NSUInteger i = 0; i < sizeof(header); i++) {
            if (header[i] != 0) { empty = NO; break; }
        }
        if (empty) break;

        char name[101] = {0};
        char prefix[156] = {0};
        char sizeText[13] = {0};
        memcpy(name, header, 100);
        memcpy(prefix, header + 345, 155);
        memcpy(sizeText, header + 124, 12);
        unsigned long long size = strtoull(sizeText, NULL, 8);
        unsigned long mode = strtoul((const char *)header + 100, NULL, 8) & 0777;
        char type = (char)header[156];

        NSString *relative = nil;
        if (type == '0' || type == '\0') {
            NSString *full = prefix[0]
                ? [NSString stringWithFormat:@"%s/%s", prefix, name]
                : [NSString stringWithUTF8String:name];
            relative = IGRStripComponents(full, strip);
        }

        if (!relative || [relative.lastPathComponent isEqualToString:@"com.apple.mobile_container_manager.metadata.plist"] ||
            [relative.lastPathComponent isEqualToString:@".DS_Store"]) {
            if (!IGRSkipBytes(gz, size)) { ok = NO; break; }
            if (!IGRSkipBytes(gz, (512 - (size % 512)) % 512)) { ok = NO; break; }
            continue;
        }

        NSString *path = [destination stringByAppendingPathComponent:relative];
        NSString *parent = path.stringByDeletingLastPathComponent;
        [manager createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];

        if (type == '5') {
            [manager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
            if (!IGRSkipBytes(gz, size)) { ok = NO; break; }
        } else if (type == '0' || type == '\0') {
            FILE *file = fopen(path.fileSystemRepresentation, "wb");
            if (!file) {
                IGRLog([NSString stringWithFormat:@"cannot write %@", path]);
                ok = NO;
                break;
            }
            unsigned long long remaining = size;
            unsigned char buffer[32768];
            while (remaining > 0) {
                NSUInteger chunk = (NSUInteger)MIN(remaining, sizeof(buffer));
                if (!IGRReadExact(gz, buffer, chunk) || fwrite(buffer, 1, chunk, file) != chunk) {
                    ok = NO;
                    break;
                }
                remaining -= chunk;
            }
            fclose(file);
            if (!ok) break;
            chmod(path.fileSystemRepresentation, mode ? mode : 0644);
            extracted++;
        } else {
            if (!IGRSkipBytes(gz, size)) { ok = NO; break; }
        }

        if (!IGRSkipBytes(gz, (512 - (size % 512)) % 512)) {
            ok = NO;
            break;
        }
    }

    gzclose(gz);
    IGRLog([NSString stringWithFormat:@"extracted %@ -> %@ files=%lu ok=%d",
            archive.lastPathComponent, destination, (unsigned long)extracted, ok]);
    return ok;
}

static BOOL IGRRestore(void) {
    NSString *backup = IGRFindBackupDirectory();
    if (!backup) {
        IGRLog(@"backup folder not found");
        return NO;
    }

    BOOL ok = YES;
    NSString *appArchive = [backup stringByAppendingPathComponent:@"com.burbn.instagram.tar.gzip"];
    ok = IGRExtractTarGz(appArchive, NSHomeDirectory(), 7) && ok;

    NSArray *groups = @[
        @[@"group.com.burbn.instagram", @"group.com.burbn.instagram_groupShared.tar.gzip"],
        @[@"group.com.facebook.family", @"group.com.facebook.family_groupShared.tar.gzip"]
    ];
    for (NSArray *group in groups) {
        NSString *identifier = group[0];
        NSString *archive = [backup stringByAppendingPathComponent:group[1]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:archive]) continue;
        NSURL *url = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:identifier];
        if (!url.path.length) {
            IGRLog([NSString stringWithFormat:@"missing group container %@", identifier]);
            ok = NO;
            continue;
        }
        ok = IGRExtractTarGz(archive, url.path, 7) && ok;
    }
    return ok;
}

%ctor {
    NSString *root = IGRDefaultsPath();
    NSString *trigger = [root stringByAppendingPathComponent:@"restore"];
    NSString *running = [root stringByAppendingPathComponent:@"restore.running"];
    NSFileManager *manager = [NSFileManager defaultManager];
    if (![manager fileExistsAtPath:trigger]) return;

    [manager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    [manager removeItemAtPath:running error:nil];
    [manager moveItemAtPath:trigger toPath:running error:nil];

    IGRLog(@"restore requested");
    BOOL ok = IGRRestore();
    NSString *result = [root stringByAppendingPathComponent:ok ? @"restore.done" : @"restore.failed"];
    [manager removeItemAtPath:result error:nil];
    [manager moveItemAtPath:running toPath:result error:nil];
    IGRLog(ok ? @"restore complete" : @"restore failed");

    if (ok) {
        usleep(300000);
        kill(getpid(), SIGKILL);
    }
}
