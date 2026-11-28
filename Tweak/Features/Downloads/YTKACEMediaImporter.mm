#import "YTKACEMediaImporter.h"
#import "FFmpegMuxer.h"
#import "MediaArtwork.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

static NSString * const YTKACEImportErrorDomain = @"YTKACEMediaImport";

static NSError *YTKACEImportError(NSString *message) {
    return [NSError errorWithDomain:YTKACEImportErrorDomain code:1
        userInfo:@{NSLocalizedDescriptionKey: YTKACELocalized(message ?: @"Import failed")}];
}

static NSSet<NSString *> *YTKACEVideoExtensions(void) {
    return [NSSet setWithArray:@[@"mp4", @"m4v", @"mov", @"webm", @"mkv"]];
}

static NSSet<NSString *> *YTKACEAudioExtensions(void) {
    return [NSSet setWithArray:@[
        @"m4a", @"mp3", @"aac", @"wav", @"flac", @"ogg", @"opus", @"webm"
    ]];
}

static NSSet<NSString *> *YTKACEImageExtensions(void) {
    return [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"heic", @"webp"]];
}

static NSSet<NSString *> *YTKACESubtitleExtensions(void) {
    return [NSSet setWithArray:@[@"srt", @"vtt"]];
}

static NSString *YTKACESafeImportName(NSString *name) {
    NSCharacterSet *invalid = [NSCharacterSet
        characterSetWithCharactersInString:@"/\\:?%*|\"<>"];
    NSString *safe = [[name componentsSeparatedByCharactersInSet:invalid]
        componentsJoinedByString:@"-"];
    return safe.length == 0 ? @"Imported Media" : safe;
}

static NSURL *YTKACEUniqueImportURL(NSURL *directory, NSString *name,
                                    NSString *extension) {
    NSURL *URL = [directory URLByAppendingPathComponent:
        [name stringByAppendingPathExtension:extension]];
    NSInteger suffix = 2;
    while ([NSFileManager.defaultManager fileExistsAtPath:URL.path]) {
        URL = [directory URLByAppendingPathComponent:
            [[NSString stringWithFormat:@"%@ %ld", name, (long)suffix++]
                stringByAppendingPathExtension:extension]];
    }
    return URL;
}

static NSString *YTKACEMediaStem(NSString *value) {
    NSString *stem = value.lowercaseString;
    for (NSString *suffix in @[
        @"-thumbnail", @"_thumbnail", @" thumbnail",
        @"-artwork", @"_artwork", @" artwork",
        @"-thumb", @"_thumb", @" thumb"
    ]) {
        if ([stem hasSuffix:suffix]) {
            stem = [stem substringToIndex:stem.length - suffix.length];
            break;
        }
    }
    return stem;
}

static NSURL *YTKACEMatchingURL(NSArray<NSURL *> *URLs, NSString *stem,
                                BOOL allowFallback) {
    NSString *mediaStem = YTKACEMediaStem(stem);
    for (NSURL *URL in URLs) {
        NSString *candidate = YTKACEMediaStem(
            URL.lastPathComponent.stringByDeletingPathExtension);
        if ([candidate isEqualToString:mediaStem]) {
            return URL;
        }
    }
    return allowFallback && URLs.count == 1 ? URLs.firstObject : nil;
}

static NSError *YTKACEWaitForRemux(NSURL *source, NSURL *destination,
                                    BOOL audioOnly) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError *result = nil;
    YTKACEFFmpegCompletion completion = ^(NSError *error) {
        result = error;
        dispatch_semaphore_signal(semaphore);
    };
    if (audioOnly) {
        [YTKACEFFmpegMuxer remuxAudioURL:source outputURL:destination
                              completion:completion];
    } else {
        [YTKACEFFmpegMuxer normalizeMediaURL:source outputURL:destination
                                  completion:completion];
    }
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    return result;
}

static NSError *YTKACEWaitForArtwork(NSData *data, NSURL *mediaURL) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError *result = nil;
    [YTKACEFFmpegMuxer embedArtworkData:data mediaURL:mediaURL
        completion:^(NSError *error) {
            result = error;
            dispatch_semaphore_signal(semaphore);
        }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    return result;
}

static NSData *YTKACEJPEGData(NSURL *URL) {
    UIImage *image = [UIImage imageWithContentsOfFile:URL.path];
    return image == nil ? nil : UIImageJPEGRepresentation(image, 0.9);
}

@implementation YTKACEMediaImporter

+ (void)importURLs:(NSArray<NSURL *> *)URLs
          category:(NSString *)category
        completion:(YTKACEMediaImportCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL audioCategory = [category isEqualToString:@"Audio"];
        NSSet *mediaExtensions = audioCategory
            ? YTKACEAudioExtensions() : YTKACEVideoExtensions();
        NSMutableArray<NSURL *> *media = [NSMutableArray array];
        NSMutableArray<NSURL *> *images = [NSMutableArray array];
        NSMutableArray<NSURL *> *subtitles = [NSMutableArray array];
        for (NSURL *URL in URLs) {
            NSString *extension = URL.pathExtension.lowercaseString;
            if ([mediaExtensions containsObject:extension]) [media addObject:URL];
            else if ([YTKACEImageExtensions() containsObject:extension]) [images addObject:URL];
            else if ([YTKACESubtitleExtensions() containsObject:extension]) [subtitles addObject:URL];
        }
        NSURL *downloads = [YTKACEApplicationSupportDirectory()
            URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
        NSURL *directory = [downloads URLByAppendingPathComponent:category isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:directory
          withIntermediateDirectories:YES attributes:nil error:nil];
        NSUInteger imported = 0;
        NSError *lastError = nil;
        for (NSURL *source in media) {
            NSError *operationError = nil;
            NSString *stem = YTKACESafeImportName(
                source.lastPathComponent.stringByDeletingPathExtension);
            NSString *extension = audioCategory ? @"m4a" : @"mp4";
            NSURL *destination = YTKACEUniqueImportURL(directory, stem, extension);
            NSURL *temporary = [directory URLByAppendingPathComponent:
                [NSString stringWithFormat:@".%@.%@", NSUUID.UUID.UUIDString, extension]];
            NSError *remuxError = YTKACEWaitForRemux(source, temporary, audioCategory);
            if (remuxError == nil) {
                [NSFileManager.defaultManager moveItemAtURL:temporary
                                                      toURL:destination error:&operationError];
            } else {
                [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
                destination = YTKACEUniqueImportURL(directory, stem,
                    source.pathExtension.lowercaseString);
                [NSFileManager.defaultManager copyItemAtURL:source
                                                       toURL:destination error:&operationError];
            }
            if (operationError != nil) {
                lastError = operationError;
                continue;
            }
            imported++;
            NSURL *image = YTKACEMatchingURL(images,
                source.lastPathComponent.stringByDeletingPathExtension,
                media.count == 1);
            NSData *artwork = image == nil
                ? YTKACEMediaArtworkData(source) : YTKACEJPEGData(image);
            if (artwork.length != 0) {
                NSURL *sidecar = [destination.URLByDeletingPathExtension
                    URLByAppendingPathExtension:@"jpg"];
                [artwork writeToURL:sidecar atomically:YES];
                if (YTKACEWaitForArtwork(artwork, destination) == nil) {
                    [NSFileManager.defaultManager removeItemAtURL:sidecar error:nil];
                }
            }
            NSURL *subtitle = YTKACEMatchingURL(subtitles,
                source.lastPathComponent.stringByDeletingPathExtension,
                media.count == 1);
            if (subtitle != nil && !audioCategory) {
                NSURL *sidecar = [destination.URLByDeletingPathExtension
                    URLByAppendingPathExtension:subtitle.pathExtension.lowercaseString];
                [NSFileManager.defaultManager copyItemAtURL:subtitle toURL:sidecar error:nil];
            }
        }
        if (media.count == 0 && !audioCategory) {
            for (NSURL *subtitle in subtitles) {
                NSString *stem = subtitle.lastPathComponent.stringByDeletingPathExtension;
                for (NSURL *existing in [NSFileManager.defaultManager
                    contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil
                    options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[]) {
                    if ([existing.lastPathComponent.stringByDeletingPathExtension
                            caseInsensitiveCompare:stem] == NSOrderedSame &&
                        [YTKACEVideoExtensions() containsObject:existing.pathExtension.lowercaseString]) {
                        NSURL *sidecar = [existing.URLByDeletingPathExtension
                            URLByAppendingPathExtension:subtitle.pathExtension.lowercaseString];
                        [NSFileManager.defaultManager removeItemAtURL:sidecar error:nil];
                        NSError *copyError = nil;
                        [NSFileManager.defaultManager copyItemAtURL:subtitle toURL:sidecar
                                                              error:&copyError];
                        if (copyError == nil) imported++;
                        else lastError = copyError;
                        break;
                    }
                }
            }
        }
        if (imported == 0 && lastError == nil) {
            lastError = YTKACEImportError(@"No matching media was selected");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter
                postNotificationName:@"YTKACEDownloadLibraryChanged" object:nil];
            completion(imported, lastError);
        });
    });
}

@end
