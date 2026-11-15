//
//  HelperFunctions.m
//  windiskwriter
//
//  Created by Macintosh on 27.01.2023.
//  Copyright © 2023 TechUnRestricted. All rights reserved.
//

#import <CommonCrypto/CommonDigest.h>

#import "NSFileManager+Common.h"
#import "LocalizedStrings.h"
#import "HelperFunctions.h"
#import "NSString+Common.h"
#import "NSError+Common.h"
#import <AppKit/AppKit.h>
#import "DiskManagerProcessor.h"
#import "CommandLine.h"
#import "SimpleDownloadManager.h"
#import "Constants.h"
#import <sys/stat.h>
#import "HDIUtil.h"

NSString * const MSDOSCompliantSymbols = @"ABCDEFGHIJKLMNOPQRSTUVWXZY0123456789";

@implementation HelperFunctions

static NSString *applicationFilesFolder;
static NSString *applicationTempFolder;

static NSString *applicationGrub4DosFolder;

static NSArray<NSString *> *grub4dosFileNames;

__attribute__((constructor))
static void initializeStaticVariables() {
    NSString *suggestedApplicationDirectoryPath;
    
    NSArray *foundDirectoriesInDomains = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (foundDirectoriesInDomains.count > 0) {
        suggestedApplicationDirectoryPath = [foundDirectoriesInDomains firstObject];
    } else {
        suggestedApplicationDirectoryPath = NSTemporaryDirectory();
    }
    
    applicationFilesFolder = [NSString pathWithComponents: @[
        suggestedApplicationDirectoryPath,
        @"WinDiskWriter"
    ]];
    
    applicationTempFolder = [NSString pathWithComponents: @[
        applicationFilesFolder,
        @"temporary-files"
    ]];
    
    applicationGrub4DosFolder = [NSString pathWithComponents: @[
        applicationFilesFolder,
        @"gru4dos"
    ]];
    
    grub4dosFileNames = @[
        @"grldr", @"grldr.mbr", @"menu.lst"
    ];
}

+ (BOOL)setAllPermissionsForPath: (NSString *)path
                           error: (NSError * _Nullable * _Nullable)error {
    const char *filePath = [path fileSystemRepresentation];
    
    if (chmod(filePath, S_IRWXU | S_IRWXG | S_IRWXO) == -1) {
        if (error) {
            *error = [NSError errorWithStringValue: [NSString stringWithUTF8String:strerror(errno)]];
        }
        
        return NO;
    }
    
    return YES;
}

+ (BOOL)fixPermissionsForBaseDirectoriesWithError: (NSError *_Nullable *_Nullable)error {
    // Application is running in normal user rights mode, don't need (and can't) change anything!
    if (![HelperFunctions hasElevatedRights]) {
        return YES;
    }
        
    for (NSString *baseDirectoryPath in @[applicationFilesFolder, applicationTempFolder, applicationGrub4DosFolder]) {
        NSError *setAllPermissionsError = NULL;
        
        [HelperFunctions setAllPermissionsForPath: baseDirectoryPath
                                            error: &setAllPermissionsError];
        
        if (setAllPermissionsError != NULL) {
            NSString *errorString = [LocalizedStrings errorTextCantSetAllPermissionsForDirectoryWithArgument1: baseDirectoryPath
                                                                                                    argument2: setAllPermissionsError.stringValue];
            if (error) {
                *error = [NSError errorWithStringValue: errorString];
            }
            
            return NO;
        }
    }
    
    return YES;
}

+ (BOOL)createBaseDirectoriesWithError: (NSError *_Nullable *_Nullable)error {
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    
    for (NSString *requiredDirectoryPath in @[applicationFilesFolder, applicationTempFolder, applicationGrub4DosFolder]) {
        NSError *createDirectoryError = NULL;
        
        [fileManager createDirectoryAtPath: requiredDirectoryPath
               withIntermediateDirectories: YES
                                attributes: NULL
                                     error: &createDirectoryError];
                
        if (createDirectoryError != NULL) {
            NSString *errorString = [LocalizedStrings errorTextCantCreateBaseDirectoryAtPathWithArgument1: requiredDirectoryPath
                                                                                                argument2: createDirectoryError.stringValue];
            if (error) {
                *error = [NSError errorWithStringValue: errorString];
            }
            
            return NO;
        }
    }
    
    return YES;
}

+ (BOOL)requiresLegacyBootloaderFilesDownload {
    return [self notDownloadedGrub4DosFilesArray].count > 0;
}

+ (NSArray<NSString *> *)notDownloadedGrub4DosFilesArray {
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    
    BOOL baseFolderExists = [fileManager folderExistsAtPath: applicationGrub4DosFolder];
    if (!baseFolderExists) {
        return grub4dosFileNames;
    }
    
    NSMutableArray *missingBootloaderFiles = [[NSMutableArray alloc] init];
    for (NSString *fileName in grub4dosFileNames) {
        NSString *pathToFile = [applicationGrub4DosFolder stringByAppendingPathComponent: fileName];
        
        BOOL fileExists = [fileManager fileExistsAtPathAndNotAFolder: pathToFile];
        if (!fileExists) {
            [missingBootloaderFiles addObject: fileName];
        }
    }
    
    return missingBootloaderFiles;
}

+ (NSString *)applicationFilesFolder {
    return applicationFilesFolder;
}

+ (NSString *)applicationTempFolder {
    return applicationTempFolder;
}

+ (NSString *)applicationGrub4DosFolder {
    return applicationGrub4DosFolder;
}

+ (NSString *)grub4DosDownloadLinkBase {
    return @"https://github.com/TechUnRestricted/wdw-component-grub4dos/releases/latest/download/";
}

+ (NSArray<NSString *> *)grub4dosFileNames {
    return grub4dosFileNames;
}

+ (void)quitApplication {
    [[NSApplication sharedApplication] terminate: NULL];
}

+ (BOOL)threadSafeRemoveFile: (NSString *)filePath
                       error: (NSError *_Nullable *_Nullable)error {
    NSFileManager *fileManager = [[NSFileManager alloc] init];

    BOOL folderExists = [fileManager fileExistsAtPath: filePath];
    if (folderExists) {
        NSError *folderRemoveError = NULL;
        
        [fileManager removeItemAtPath: filePath
                                error: &folderRemoveError];
        
        if (folderRemoveError) {
            if (error) {
                *error = folderRemoveError;
            }
            
            return NO;
        }
    }
    
    return YES;
}

+ (void)resetApplicationSettings {
    [self threadSafeRemoveFile: applicationFilesFolder
                         error: NULL];
        
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *defaultsDictionary = [userDefaults dictionaryRepresentation];
    
    for (NSString *key in [defaultsDictionary allKeys]) {
        [userDefaults removeObjectForKey:key];
    }
    
    [userDefaults synchronize];
}

+ (BOOL)cleanupTempFoldersWithError: (NSError *_Nullable *_Nullable)error {
    NSError *threadSafeRemoveFileError = NULL;
    
    [self threadSafeRemoveFile: applicationTempFolder
                         error: &threadSafeRemoveFileError];
    
    if (threadSafeRemoveFileError != NULL) {
        if (error) {
            *error = threadSafeRemoveFileError;
        }
        
        return NO;
    }
    
    return YES;
}

+ (BOOL)hasElevatedRights {
    return geteuid() == 0;
}

+ (void)openDonationsPage {
    NSURL *url = [NSURL URLWithString: @"https://github.com/TechUnRestricted/windiskwriter"];
    [[NSWorkspace sharedWorkspace] openURL: url];
}

+ (void)printTimeElapsedWhenRunningCode: (NSString *)title
                              operation: (void (^)(void))operation {
    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    operation();
    CFAbsoluteTime timeElapsed = CFAbsoluteTimeGetCurrent() - startTime;
    
    // Doesn't need to be translated, since it's only used for debugging purposes
    NSLog(@"Time elapsed for %@: %f s.", title, timeElapsed);
}

+ (NSString *)randomStringWithLength: (UInt64)requiredLength {
    NSMutableString *generatedString = [NSMutableString stringWithCapacity:requiredLength];
    
    for (NSUInteger i = 0U; i < requiredLength; i++) {
        u_int32_t r = arc4random() % [MSDOSCompliantSymbols length];
        unichar c = [MSDOSCompliantSymbols characterAtIndex:r];
        [generatedString appendFormat:@"%C", c];
    }
    
    return generatedString;
}

+ (void)restartAppWithElevatedPermissions: (BOOL)withElevatedPermissions
                                    error: (NSError **)error {
    NSArray<NSString *> *argumentsList = NSProcessInfo.processInfo.arguments;
    if (argumentsList.count == 0) {
        if (error) {
            *error = [NSError errorWithStringValue: [LocalizedStrings errorTextApplicationArgumentsListIsEmpty]];
        }
        
        return;
    }
    
    NSString *executablePath = [argumentsList firstObject];
    if (![[NSFileManager defaultManager] fileExistsAtPath: executablePath]) {
        if (error) {
            *error = [NSError errorWithStringValue: [LocalizedStrings errorTextApplicationArgumentsBadStructure]];
        }
        
        return;
    }
    
    if (!withElevatedPermissions) {
        [CommandLine execute: @"/usr/bin/open"
                   arguments: @[@"-n", @"-a", executablePath]
                   exception: NULL];
                
        [[NSApplication sharedApplication] terminate: NULL];
    } else {
        AuthorizationRef authorizationRef;
        AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, kAuthorizationFlagPreAuthorize, &authorizationRef);
        
        char *cExecutablePath = (char *)[executablePath cStringUsingEncoding: NSUTF8StringEncoding];
        char *args[] = {NULL};
        
        OSStatus executionStatus = AuthorizationExecuteWithPrivileges(authorizationRef, cExecutablePath, kAuthorizationFlagDefaults, args, NULL);
        
        NSString *executionErrorString = NULL;
        
        switch (executionStatus) {
            case errAuthorizationSuccess:
                [[NSApplication sharedApplication] terminate: NULL];
                break;
            case errAuthorizationInvalidSet:
                executionErrorString = [LocalizedStrings authorizationErrorInvalidSet];
                break;
            case errAuthorizationInvalidRef:
                executionErrorString = [LocalizedStrings authorizationErrorInvalidRef];
                break;
            case errAuthorizationInvalidTag:
                executionErrorString = [LocalizedStrings authorizationErrorInvalidTag];
                break;
            case errAuthorizationInvalidPointer:
                executionErrorString = [LocalizedStrings authorizationErrorInvalidPointer];
                break;
            case errAuthorizationDenied:
                executionErrorString = [LocalizedStrings authorizationErrorDenied];
                break;
            case errAuthorizationCanceled:
                executionErrorString = [LocalizedStrings authorizationErrorCanceled];
                break;
            case errAuthorizationInteractionNotAllowed:
                executionErrorString = [LocalizedStrings authorizationErrorInteractionNotAllowed];
                break;
            case errAuthorizationInternal:
                executionErrorString = [LocalizedStrings authorizationErrorInternal];
                break;
            case errAuthorizationExternalizeNotAllowed:
                executionErrorString = [LocalizedStrings authorizationErrorExternalizeNotAllowed];
                break;
            case errAuthorizationInternalizeNotAllowed:
                executionErrorString = [LocalizedStrings authorizationErrorInternalizeNotAllowed];
                break;
            case errAuthorizationInvalidFlags:
                executionErrorString = [LocalizedStrings authorizationErrorInvalidFlags];
                break;
            case errAuthorizationToolExecuteFailure:
                executionErrorString = [LocalizedStrings authorizationErrorToolExecuteFailure];
                break;
            case errAuthorizationToolEnvironmentError:
                executionErrorString = [LocalizedStrings authorizationErrorToolEnvironmentError];
                break;
            case errAuthorizationBadAddress:
                executionErrorString = [LocalizedStrings authorizationErrorBadAddress];
                break;
        }

        if (authorizationRef != NULL) {
            AuthorizationFree(authorizationRef, kAuthorizationFlagPreAuthorize);
        }
        
        if (error) {
            *error = [NSError errorWithStringValue: executionErrorString];
        }
    }
    
    return;
}

+ (NSString *_Nullable)windowsSourceMountPath: (NSString *_Nonnull)sourcePath
                                        error: (NSError *_Nullable *_Nullable)error {
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    
    BOOL isDirectory;
    BOOL exists = [fileManager fileExistsAtPath:sourcePath isDirectory:&isDirectory];
    
    if (!exists) {
        if (error) {
            // ERROR_FILE_OR_DIRECTORY_DOESNT_EXIST
            *error = [NSError errorWithStringValue: [LocalizedStrings errorFileOrDirectoryDoesntExistWithArgument1: sourcePath]];
        }
        
        return NULL;
    }
    
    if (isDirectory) {
        return sourcePath;
    }
    
    if (![[[sourcePath lowercaseString] pathExtension] isEqualToString: @"iso"]) {
        if (error) {
            *error = [NSError errorWithStringValue: [LocalizedStrings errorTextFileTypeIsNotIso]];
        }
        
        return NULL;
    }
    
    HDIUtil *hdiutil = [[HDIUtil alloc] initWithImagePath:sourcePath];
    if([hdiutil attachImageWithArguments:@[@"-readonly", @"-noverify", @"-noautofsck", @"-noautoopen"]
                                   error: error]) {
        return [hdiutil mountPoint];
    }
    
    return NULL;
}

+ (DiskManagerProcessor *_Nullable)diskManagerWithDevicePath: (NSString *)devicePath
                                        isBSDDevice: (BOOL *_Nullable)isBSDDevice
                                              error: (NSError *_Nullable *_Nullable)error {
    
    if ([DiskManagerProcessor isBSDPath:devicePath]) {
        if (isBSDDevice != NULL) {
            *isBSDDevice = YES;
        }
        
        /* Received device destination path was defined as BSD Name. */
        return [[DiskManagerProcessor alloc] initWithBSDName:devicePath];
    }
    else if ([devicePath hasPrefix:@"/Volumes/"]) {
        if (isBSDDevice != NULL) {
            *isBSDDevice = NO;
        }
        
        NSFileManager *fileManager = [[NSFileManager alloc] init];
        BOOL isDirectory;
        BOOL exists = [fileManager fileExistsAtPath:devicePath isDirectory:&isDirectory];
        
        if (!exists) {
            if (error) {
                *error = [NSError errorWithStringValue: [LocalizedStrings errorTextDestinationPathDoesNotExist]];
            }
            
            return NULL;
        }
        
        /* Received device destination path was defined as Mounted Volume. */
        if (@available(macOS 10.7, *)) {
            return [[DiskManagerProcessor alloc] initWithVolumePath:devicePath];
        } else {
            // TODO: Fix Mac OS X 10.6 Snow Leopard support
            if (error) {
                *error = [NSError errorWithStringValue: [LocalizedStrings errorTextInitWithVolumePathUnsupported]];
            }
            
            return NULL;
        }
    }
    return NULL;
}

+ (NSString *)unitFormattedSizeFor: (UInt64)bytes {
    double doubleBytes = bytes;
    
    NSArray *units = @[
        @"B", @"KB", @"MB", @"GB", @"TB", @"PB", @"EB"
    ];
    
    UInt8 unitPosition = 0;
    
    while (doubleBytes > 1000) {
        doubleBytes /= 1000;
        unitPosition += 1;
    }
    
    return [NSString stringWithFormat:@"%.2f %@",
            doubleBytes,
            [units objectAtIndex:unitPosition]
    ];
}

// Fix for TechUnRestricted/windiskwriter#75 and #29: written files are verified
// after the copy loop, so an unexpected disconnect or a read-only mount shows
// up as a verification failure instead of a silent broken installer.
+ (NSString * _Nullable)sha256ForFileAtPath: (NSString * _Nonnull)path {
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath: path];
    if (fileHandle == NULL) {
        return NULL;
    }

    CC_SHA256_CTX sha256Context;
    CC_SHA256_Init(&sha256Context);

    const uint64_t bufferSize = 8 * 1024 * 1024;
    void *buffer = malloc(bufferSize);
    if (buffer == NULL) {
        [fileHandle closeFile];
        return NULL;
    }

    while (true) {
        NSData *chunk = [fileHandle readDataOfLength: bufferSize];
        if (chunk.length == 0) {
            break;
        }

        CC_SHA256_Update(&sha256Context, chunk.bytes, (CC_LONG)chunk.length);
    }

    free(buffer);
    [fileHandle closeFile];

    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &sha256Context);

    NSMutableString *hashString = [NSMutableString stringWithCapacity: CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hashString appendFormat: @"%02x", digest[i]];
    }

    return hashString;
}

// Official-ISO download (software-download-connector API). Microsoft requires
// a per-session handshake before the API answers: the session GUID must be
// whitelisted via vlscppe tags, then confirmed through the ov-df challenge
// (mdt.js provides the w/rticks parameters for that reply).
+ (NSData * _Nullable)msISOHttpGet: (NSURL *)url
                           referer: (NSString * _Nullable)referer
                             error: (NSError *_Nullable *_Nullable)error {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL: url
                                                           cachePolicy: NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval: 30.0];

    if (referer != NULL) {
        [request setValue: referer forHTTPHeaderField: @"Referer"];
    }

    __block NSData *responseData = NULL;
    __block NSError *requestError = NULL;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest: request
                                                                 completionHandler: ^(NSData *data, NSURLResponse *response, NSError *taskError) {
        NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
        if (taskError == NULL && statusCode >= 200 && statusCode < 400) {
            responseData = data;
        } else if (taskError != NULL) {
            requestError = taskError;
        } else {
            requestError = [NSError errorWithStringValue: [NSString stringWithFormat: @"HTTP %ld", (long)statusCode]];
        }

        dispatch_semaphore_signal(semaphore);
    }];

    [task resume];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    if (error) {
        *error = requestError;
    }

    return responseData;
}

// Runs the whole ov-df challenge for one session GUID: whitelist the session,
// fetch mdt.js for the w/rticks parameters, then send the signed reply.
+ (BOOL)msISOPreflightSession: (NSString *)sessionId
                     instance: (NSString *)instanceId
                        error: (NSError *_Nullable *_Nullable)error {
    NSString *orgId = @"y6jn8c31";

    NSURL *tagsURL = [NSURL URLWithString: [NSString stringWithFormat:
        @"https://vlscppe.microsoft.com/tags?org_id=%@&session_id=%@", orgId, sessionId]];
    [self msISOHttpGet: tagsURL referer: NULL error: NULL];

    NSData *mdtData = [self msISOHttpGet: [NSURL URLWithString: [NSString stringWithFormat:
        @"https://ov-df.microsoft.com/mdt.js?instanceId=%@&PageId=si&session_id=%@", instanceId, sessionId]]
                    referer: NULL
                      error: error];
    if (mdtData == NULL) {
        return NO;
    }

    NSString *mdtContent = [[NSString alloc] initWithData: mdtData encoding: NSUTF8StringEncoding];

    NSString *wParameter = NULL;
    NSRegularExpression *wExpression = [NSRegularExpression regularExpressionWithPattern: @"[?&]w=([A-F0-9]+)"
                                                                                options: 0 error: NULL];
    NSTextCheckingResult *wMatch = [wExpression firstMatchInString: mdtContent options: 0 range: NSMakeRange(0, mdtContent.length)];
    if (wMatch.numberOfRanges > 1) {
        wParameter = [mdtContent substringWithRange: [wMatch rangeAtIndex: 1]];
    }

    NSString *rticksParameter = NULL;
    NSRegularExpression *rticksExpression = [NSRegularExpression regularExpressionWithPattern: @"rticks=\\\"\\+?(\\d+)"
                                                                                     options: 0 error: NULL];
    NSTextCheckingResult *rticksMatch = [rticksExpression firstMatchInString: mdtContent options: 0 range: NSMakeRange(0, mdtContent.length)];
    if (rticksMatch.numberOfRanges > 1) {
        rticksParameter = [mdtContent substringWithRange: [rticksMatch rangeAtIndex: 1]];
    }

    if (wParameter == NULL || rticksParameter == NULL) {
        if (error) {
            *error = [NSError errorWithStringValue: @"Could not extract ov-df data"];
        }

        return NO;
    }

    NSURL *replyURL = [NSURL URLWithString: [NSString stringWithFormat:
        @"https://ov-df.microsoft.com/?session_id=%@&CustomerId=%@&PageId=si&w=%@&mdt=%lld&rticks=%@",
        sessionId, instanceId, wParameter, (long long)([[NSDate date] timeIntervalSince1970] * 1000.0), rticksParameter]];

    NSData *replyData = [self msISOHttpGet: replyURL referer: NULL error: error];

    return replyData != NULL;
}

+ (void)downloadOfficialWindows11ISOWithLocale: (NSString *)locale
                                statusCallback: (MSISOStatusCallback)statusCallback
                                    completion: (MSISOCompletionCallback)completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        void (^statusBlock)(NSString *text) = ^(NSString *text) {
            dispatch_async(dispatch_get_main_queue(), ^{ statusCallback(text); });
        };

        NSError *flowError = NULL;
        NSString *chosenSKUId = NULL;
        NSString *chosenSessionId = NULL;
        NSString *referencedLocale = [locale lowercaseString];

        // 3813 = Home/Pro/Edu x64 image, 3816 = the same for ARM64 (Microsoft
        // assigns separate edition IDs per architecture).
        for (NSNumber *editionId in @[@3813, @3816]) {
            NSString *sessionId = [[NSUUID UUID] UUIDString].lowercaseString;
            NSString *instanceId = @"560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175";

            if (![self msISOPreflightSession: sessionId instance: instanceId error: &flowError]) {
                break;
            }

            NSURL *skuURL = [NSURL URLWithString: [NSString stringWithFormat:
                @"https://www.microsoft.com/software-download-connector/api/getskuinformationbyproductedition"
                @"?profile=606624d44113&productEditionId=%@&SKU=undefined&friendlyFileName=undefined&Locale=%@&sessionID=%@",
                editionId, referencedLocale, sessionId]];

            NSData *skuData = [self msISOHttpGet: skuURL referer: NULL error: &flowError];
            if (skuData == NULL) {
                break;
            }

            id skuJSON = [NSJSONSerialization JSONObjectWithData: skuData options: 0 error: NULL];
            NSArray *skus = [skuJSON objectForKey: @"Skus"];
            if (skus.count == 0) {
                continue;
            }

            // The API names languages in English ("Russian", "English"...), so the
            // system locale prefix maps to a language-name substring. English wins
            // as the fallback when the mapping has no entry.
            NSDictionary *languageNameByPrefix = @{
                @"ru": @"Russian", @"en": @"English", @"de": @"German", @"fr": @"French",
                @"es": @"Spanish", @"it": @"Italian", @"pt": @"Portuguese", @"zh": @"Chinese",
                @"ja": @"Japanese", @"ko": @"Korean", @"pl": @"Polish", @"nl": @"Dutch",
                @"tr": @"Turkish", @"uk": @"Ukrainian", @"cs": @"Czech", @"ar": @"Arabic",
                @"hu": @"Hungarian", @"bg": @"Bulgarian", @"sv": @"Swedish"
            };
            NSString *languagePrefix = [referencedLocale componentsSeparatedByString: @"-"].firstObject;
            NSString *preferredLanguageName = languageNameByPrefix[languagePrefix] ?: @"English";

            for (NSDictionary *sku in skus) {
                NSString *skuLanguage = [sku objectForKey: @"Language"];

                if ([skuLanguage localizedCaseInsensitiveContainsString: preferredLanguageName]) {
                    chosenSKUId = [NSString stringWithFormat: @"%@", [sku objectForKey: @"Id"]];
                    chosenSessionId = sessionId;
                    break;
                }
            }

            if (chosenSKUId != NULL) break;
        }

        if (chosenSKUId == NULL) {
            if (flowError == NULL) {
                flowError = [NSError errorWithStringValue: @"Could not retrieve languages from server"];
            }

            dispatch_async(dispatch_get_main_queue(), ^{ completion(NULL, flowError); });
            return;
        }

        statusBlock([LocalizedStrings msISOStatusFetchingDownloadLinks]);

        NSURL *linksURL = [NSURL URLWithString: [NSString stringWithFormat:
            @"https://www.microsoft.com/software-download-connector/api/GetProductDownloadLinksBySku"
            @"?profile=606624d44113&productEditionId=undefined&SKU=%@&friendlyFileName=undefined&Locale=%@&sessionID=%@",
            chosenSKUId, referencedLocale, chosenSessionId]];

        NSData *linksData = [self msISOHttpGet: linksURL
                                       referer: @"https://www.microsoft.com/software-download/windows11"
                                         error: &flowError];
        if (linksData == NULL) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NULL, flowError); });
            return;
        }

        id linksJSON = [NSJSONSerialization JSONObjectWithData: linksData options: 0 error: NULL];
        NSArray *downloadOptions = [linksJSON objectForKey: @"ProductDownloadOptions"];

        // DownloadType: 0 = x86, 1 = x64, 2 = ARM64. Prefer x64 when present.
        NSDictionary *chosenLink = NULL;
        for (NSDictionary *option in downloadOptions) {
            if ([option objectForKey: @"DownloadType"] != NULL && [[option objectForKey: @"DownloadType"] integerValue] == 1) {
                chosenLink = option;
                break;
            }
        }

        if (chosenLink == NULL && downloadOptions.count > 0) {
            chosenLink = downloadOptions.firstObject;
        }

        NSString *downloadURLString = [chosenLink objectForKey: @"Uri"];
        if (chosenLink == NULL || downloadURLString.length == 0) {
            flowError = [NSError errorWithStringValue: @"Could not retrieve ISO download links"];

            dispatch_async(dispatch_get_main_queue(), ^{ completion(NULL, flowError); });
            return;
        }

        // The links are time-limited Azure URLs; the file name is the last path component.
        NSURL *downloadURL = [NSURL URLWithString: downloadURLString];
        NSString *fileName = downloadURL.lastPathComponent;
        if (![fileName.lowercaseString hasSuffix: @".iso"]) {
            fileName = [fileName stringByAppendingPathExtension: @"iso"];
        }

        NSString *destinationPath = [NSHomeDirectory() stringByAppendingPathComponent:
                                     [@"Downloads" stringByAppendingPathComponent: fileName]];

        statusBlock([LocalizedStrings msISOStatusDownloadingImage]);

        SimpleDownloadManager *downloadManager = [[SimpleDownloadManager alloc] initWithSourceURL: downloadURL
                                                                                  destinationPath: destinationPath
                                                                                temporaryFilePath: [destinationPath stringByAppendingString: @".part"]];

        __block NSString *downloadErrorText = NULL;
        BOOL downloadSuccessful = [downloadManager downloadFileSynchronouslyWithCallback: ^BOOL(SDMMessage message, SDMMessageType messageType, void *SDMCallbackStruct, NSError *error) {
            if (message == SDMMessageDidFailWithError || messageType == SDMMessageTypeFailure) {
                downloadErrorText = error.localizedDescription ?: @"Download failed";
                return NO;
            }

            if (message == SDMMessageDidReceiveData) {
                SDMCallbackStructDidReceiveData *callbackStruct = (SDMCallbackStructDidReceiveData *)SDMCallbackStruct;
                if (callbackStruct->expectedFileSize > 0) {
                    statusBlock([NSString stringWithFormat: @"%.1f%%",
                                 100.0 * callbackStruct->downloadedBytesSize / callbackStruct->expectedFileSize]);
                }
            }

            return YES;
        }];

        if (!downloadSuccessful) {
            flowError = [NSError errorWithStringValue: downloadErrorText ?: @"Download failed"];

            dispatch_async(dispatch_get_main_queue(), ^{ completion(NULL, flowError); });
            return;
        }

        NSString *completionPath = destinationPath;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(completionPath, NULL); });
    });
}

@end
