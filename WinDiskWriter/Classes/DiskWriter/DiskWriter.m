//
//  DiskWriter.m
//  windiskwriter
//
//  Created by Macintosh on 26.01.2023.
//  Copyright © 2023 TechUnRestricted. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <unistd.h>
#import "CommandLine.h"
#import "NSFileManager+Common.h"
#import "DWFilesContainer.h"
#import "LocalizedStrings.h"
#import "HelperFunctions.h"
#import "NSString+Common.h"
#import "NSError+Common.h"
#import "WimlibWrapper.h"
#include <sys/statvfs.h>
#import "DiskManagerProcessor.h"
#import "Filesystems.h"
#import "DiskWriter.h"
#import "constants.h"
#import "HDIUtil.h"

const uint32_t FAT32_MAX_FILE_SIZE = UINT32_MAX;

// 32MB Buffer for copying files with interrupt-like callback — larger chunks
// mean fewer copies and fewer callback round-trips on slow USB volumes (#55).
const uint64_t COPY_BUFFER_SIZE = 33554432;

static const NSString *BUNDLE_BOOTLOADER_SUBDIRECTORY_NAME = @"grub4dos";

@implementation DiskWriter {
    NSFileManager *localFileManager;
}

- (instancetype)initWithDWFilesContainer: (DWFilesContainer *)filesContainer
                         destinationPath: (NSString *)destinationPath
                  destinationDiskManager: (DiskManagerProcessor *)destinationDiskManager {
    self = [super init];
    
    // Just in case ¯\_(ツ)_/¯
    localFileManager = [NSFileManager defaultManager];
    
    _filesContainer = filesContainer;
    _destinationPath = destinationPath;
    _destinationDiskManager = destinationDiskManager;
    
    // Default constructor values
    _destinationFilesystem = FilesystemFAT32;
    _patchInstallerRequirements = NO;
    _installLegacyBoot = NO;
    _addEiCfgFile = NO;
    _addUnattendFile = NO;
    
    return self;
}

+ (NSString *)bootloaderGrldrMBRFilePath {
    return [[HelperFunctions applicationGrub4DosFolder] stringByAppendingPathComponent: @"grldr.mbr"];
}

+ (NSString *)bootloaderGrldrFilePath {
    return [[HelperFunctions applicationGrub4DosFolder] stringByAppendingPathComponent: @"grldr"];
}

+ (NSString *)bootloaderMenuLstFilePath {
    return [[HelperFunctions applicationGrub4DosFolder] stringByAppendingPathComponent: @"menu.lst"];
}

- (BOOL)writeLegacyBootSectorWithError: (NSError **)error {
    NSString *bootloaderMBRFilePath = [DiskWriter bootloaderGrldrMBRFilePath];
    NSString *bootloaderGrldrFilePath = [DiskWriter bootloaderGrldrFilePath];
    NSString *bootloaderMenuFilePath = [DiskWriter bootloaderMenuLstFilePath];

    DiskInfo *destinationDiskInfo = [self.destinationDiskManager diskInfo];
    NSString *bsdFullPath = [destinationDiskInfo BSDFullPath];
    
    if (bsdFullPath == NULL) {
        *error = [NSError errorWithStringValue: [LocalizedStrings errorTextCantDetermineBsdPath]];
        
        return NO;
    }
    
    if(![localFileManager fileExistsAtPathAndNotAFolder: bootloaderMBRFilePath]) {
        *error = [NSError errorWithStringValue: [LocalizedStrings errorTextBootloaderMbrFileDoesntExist]];
        
        return NO;
    }
    
    if(![localFileManager fileExistsAtPathAndNotAFolder: bootloaderGrldrFilePath]) {
        *error = [NSError errorWithStringValue: [LocalizedStrings errorTextBootloaderGrldrFileDoesntExist]];
        
        return NO;
    }
    
    if(![localFileManager fileExistsAtPathAndNotAFolder: bootloaderMenuFilePath]) {
        *error = [NSError errorWithStringValue: [LocalizedStrings errorTextBootloaderMenuFileDoesntExist]];
        
        return NO;
    }
    
    for (NSString *currentFile in @[bootloaderGrldrFilePath, bootloaderMenuFilePath]) {
        NSError *bootloaderFileCopyError = NULL;
        
        NSString *destinationPath = [self.destinationPath stringByAppendingPathComponent: currentFile.lastPathComponent];
        
        [localFileManager copyItemAtPath: currentFile
                                  toPath: destinationPath
                                   error: &bootloaderFileCopyError];
        
        if (bootloaderFileCopyError != NULL) {
            NSString *errorString = [
                NSString stringWithFormat: @"%@ (%@).",
                [LocalizedStrings errorCantCopyFileToDestinationDeviceWithArgument1: currentFile.lastPathComponent],
                bootloaderFileCopyError.stringValue
            ];
            
            *error = [NSError errorWithStringValue: errorString];
            
            return NO;
        }
    }
    
    // Unmounting the destination device in order to install the boot sector.
    NSError *unmountError = NULL;
    BOOL unmountWasSuccessful = [self.destinationDiskManager unmountDiskWithOptions: kDADiskUnmountOptionForce | kDADiskUnmountOptionWhole
                                                                              error: &unmountError];
    
    if (unmountError != NULL) {
        NSString *errorString = [NSString stringWithFormat: @"%@ (%@).", [LocalizedStrings errorTextUnmountDestinationDeviceFailure], unmountError.stringValue];
        
        *error = [NSError errorWithStringValue: errorString];
        
        return NO;
    }
    
    NSFileHandle *inputHandle = [NSFileHandle fileHandleForReadingAtPath: bootloaderMBRFilePath];
    if (inputHandle == NULL) {
        *error = [NSError errorWithStringValue: [LocalizedStrings errorTextBootloaderMbrOpenFileInputHandleFailure]];
        
        return NO;
    }
    
    NSFileHandle *outputHandle = [NSFileHandle fileHandleForWritingAtPath: bsdFullPath];
    if (outputHandle == NULL) {
        *error = [NSError errorWithStringValue: [LocalizedStrings errorTextOutputDeviceOpenFailure]];
        
        return NO;
    }
    
    @try {
        // Copy the first 446 bytes from the input to the output
        NSData *data = [inputHandle readDataOfLength:446];
        [outputHandle writeData:data];
        
        // Seek to the 512th byte in the input and the output
        [inputHandle seekToFileOffset:512];
        [outputHandle seekToFileOffset:512];
        
        // Copy the remaining bytes from the input to the output
        while ((data = [inputHandle readDataOfLength:512]).length > 0) {
            [outputHandle writeData:data];
        }
        
        [outputHandle synchronizeFile];
    } @catch (NSException *exception) {
        NSString *string = [NSString stringWithFormat: @"Can't complete the legacy bootloader install stage (%@).", exception.reason];
        
        *error = [NSError errorWithStringValue: string];
    }
    
    // Close the files
    [inputHandle closeFile];
    [outputHandle closeFile];
    
    return *error == NULL;
}

- (UInt64)freeSpaceAtPath: (NSString *)path
                    error: (NSError **)error {
    struct statvfs stat;
    
    if (statvfs([path UTF8String], &stat) != 0) {
        *error = [NSError errorWithStringValue: [LocalizedStrings errorTextGetAvailableSpaceFailure]];
        return 0;
    }
    
    // the available size is f_frsize * f_bavail
    return stat.f_frsize * stat.f_bavail;
}

- (BOOL)copyFileWithDWFile: (DWFile *)dwFile
       destinationFilePath: (NSString *)destinationFilePath
                bufferSize: (NSUInteger)bufferSize
     ignoreFilesystemCheck: (BOOL)ignoreFilesystemCheck
                  callback: (ChainedCallbackAction)callback {
    
    /*
     Macro for handling callback
     */
#define CallbackHandler(dwFile, writtenBytes, operationType, operationResult, error)                    \
switch (callback(dwFile, writtenBytes, operationType, operationResult, error)) {                        \
case DWActionContinue:                                                                                  \
break;                                                                                                  \
case DWActionSkip:                                                                                      \
case DWActionStop:                                                                                      \
return NO;                                                                                              \
}

#define CallbackHandlerWithCleanupOnStop(dwFile, writtenBytes, operationType, operationResult, error)     \
switch (callback(dwFile, writtenBytes, operationType, operationResult, error)) {                          \
case DWActionContinue:                                                                                    \
break;                                                                                                    \
case DWActionSkip:                                                                                        \
case DWActionStop: {                                                                                      \
free(buffer);                                                                                             \
fclose(source);                                                                                           \
fclose(destination);                                                                                      \
return NO;                                                                                                \
}                                                                                                         \
}

//
    NSString *sourcePath = [self.filesContainer.containerPath stringByAppendingPathComponent: dwFile.sourcePath];
    
    NSError *freeSpaceInPathError = NULL;
    UInt64 availableSpace = [self freeSpaceAtPath: [destinationFilePath stringByDeletingLastPathComponent]
                                            error: &freeSpaceInPathError];
    
    if (freeSpaceInPathError != NULL) {
        CallbackHandler(dwFile, 0, DWOperationTypeWriteFile, DWOperationResultFailure, freeSpaceInPathError);
        
        return NO;
    }
    
    if (dwFile.size > availableSpace) {
        NSError *error = [NSError errorWithStringValue: [LocalizedStrings errorTextDiskSpaceNotEnough]];
        
        CallbackHandler(dwFile, 0, DWOperationTypeWriteFile, DWOperationResultFailure, error);
        
        return NO;
    }
    
    // Check if we can write a file to the destination filesystem
    if ((self.destinationFilesystem == FilesystemFAT32 && dwFile.size > FAT32_MAX_FILE_SIZE) && !ignoreFilesystemCheck) {
        NSError *error = [NSError errorWithStringValue: [LocalizedStrings errorTextFileCopyFailureOverFat32SizeLimit]];
        
        CallbackHandler(dwFile, 0, DWOperationTypeWriteFile, DWOperationResultFailure, error);
        
        return NO;
    }
    
    // Open the source file in read mode
    FILE *source = fopen([sourcePath UTF8String], "rb");
    if (source == NULL) {
        NSError *error = [NSError errorWithStringValue: [LocalizedStrings errorTextOpenSourceFileFailure]];
        
        CallbackHandler(dwFile, 0, DWOperationTypeWriteFile, DWOperationResultFailure, error);
        
        return NO;
    }
    
    // Open the destination file in write mode
    FILE *destination = fopen([destinationFilePath UTF8String], "wb");
    if (destination == NULL) {
        NSError *error = [NSError errorWithStringValue: [LocalizedStrings errorTextOpenDestinationPathFailure]];
        
        fclose(source);
        
        CallbackHandler(dwFile, 0, DWOperationTypeWriteFile, DWOperationResultFailure, error);
        
        return NO;
    }
    
    // Allocate a buffer
    char *buffer = malloc(bufferSize);
    if (buffer == NULL) {
        NSError *error = [NSError errorWithStringValue: [LocalizedStrings errorTextAllocateMemoryBufferFailure]];
        
        fclose(source);
        fclose(destination);
        
        CallbackHandler(dwFile, 0, DWOperationTypeWriteFile, DWOperationResultFailure, error);
        
        return NO;
    }
    
    // Checking the size once again because it can be changed by user or system ¯\_(ツ)_/¯
    fseek(source, 0, SEEK_END);
    uint64_t sourceSize = ftell(source);
    //[dwFile setSize: sourceSize];
    
    fseek(source, 0, SEEK_SET);
    
    // Initialize the progress variables
    uint64_t bytesRead = 0;
    uint64_t bytesWritten = 0;
    
    CallbackHandlerWithCleanupOnStop(dwFile, 0, DWOperationTypeWriteFile, DWOperationResultStart, NULL);
    
    // Copy the file using the buffer
    while (true) {
        
        size_t read_size = fread(buffer, 1, bufferSize, source);
        if (read_size == 0) {
            // End of file reached
            break;
        }
        
        // Write the chunk of data to the destination file
        size_t write_size = fwrite(buffer, 1, read_size, destination);
        if (write_size != read_size) {
            NSError *error = [NSError errorWithStringValue: [LocalizedStrings errorTextWriteDestinationPathDataFailure]];
            
            free(buffer);
            fclose(source);
            fclose(destination);
            
            CallbackHandler(dwFile, bytesWritten, DWOperationTypeWriteFile, DWOperationResultFailure, error);
            
            return NO;
        }
        
        // Update the progress variables
        bytesRead += read_size;
        bytesWritten += write_size;
        
        CallbackHandlerWithCleanupOnStop(dwFile, bytesWritten, DWOperationTypeWriteFile, DWOperationResultProcess, NULL);
    }
    
    // Free the buffer and close the files
    free(buffer);
    fclose(source);
    fclose(destination);
    
    CallbackHandler(dwFile, bytesWritten, DWOperationTypeWriteFile, DWOperationResultSuccess, NULL);
    
    return YES;
}

- (BOOL)writeWindowsInstallWithDWFile: (DWFile *)dwFile
                      destinationPath: (NSString *)destinationPath
                             callback: (ChainedCallbackAction)callback {
    
    /*
     Macro for handling callback with cleanup of temporary files.
     We need it since we are make a copy of Windows Install Image on the system drive in order to patch it.
     I don't think that there can be a better solution without "goto cleanup" and macros.
     */
    
#define CallbackHandlerWithCleanup(dwFile, writtenBytes, operationType, operationResult, error)                 \
switch (callback(dwFile, writtenBytes, operationType, operationResult, error)) {                                \
case DWActionContinue:                                                                                          \
break;                                                                                                          \
case DWActionSkip:                                                                                              \
case DWActionStop:                                                                                              \
goto cleanup;                                                                                                   \
}

//
    NSString *sourcePath = [self.filesContainer.containerPath stringByAppendingPathComponent:dwFile.sourcePath];
    
    // Determining the success of the operation for "goto cleanup"
    BOOL operationWasSuccessful = NO;
    
    /*
     [Windows Image Install File is less than FAT32 max file size limit]
     or
     [Selected Filesystem is not FAT32]
     */
    
    BOOL requiresSplitting = !((dwFile.size <= FAT32_MAX_FILE_SIZE && self.destinationFilesystem == FilesystemFAT32) || self.destinationFilesystem == FilesystemExFAT);
    NSString *tempDirectory = NULL;
    
    // Check if we can write Windows Image file without modifications
    if (!requiresSplitting) {
        
        __block DWAction latestAction = DWActionContinue;
        
        // Copying Windows Image
        BOOL copyWasSuccessfull = [self copyFileWithDWFile: dwFile
                                       destinationFilePath: destinationPath
                                                bufferSize: COPY_BUFFER_SIZE
                                     ignoreFilesystemCheck: YES
                                                  callback: ^DWAction(DWFile *dwFile, uint64 copiedBytes, DWOperationType operationType, DWOperationResult operationResult, NSError *error) {
            
            latestAction = callback(dwFile, copiedBytes, operationType, operationResult, error);
            
            return latestAction;
        }];
        
        // We don't need to continue unless copying wasn't successful. All further operations require a success from the previous operation.
        if (!copyWasSuccessfull) {
            goto cleanup;
        }
        
        if (latestAction == DWActionStop) {
            goto cleanup;
        }
        
    } else {
        // Fix for TechUnRestricted/windiskwriter#36: an .esd is still a WIM
        // container (ESD-compressed), and wimlib splits it just like a plain
        // .wim — Windows Setup accepts the resulting install.swm the same way.
        // Only already-split .swm input is unsupported (re-splitting needs a merge).
        if (![sourcePath.lowercaseString.pathExtension isEqualToString:@"wim"] &&
            ![sourcePath.lowercaseString.pathExtension isEqualToString:@"esd"]) {
            NSError *error = [NSError errorWithStringValue: [LocalizedStrings errorTextSplittingEsdSwmNotSupported]];
            
            CallbackHandlerWithCleanup(dwFile, 0, DWOperationTypeSplitWindowsImage, DWOperationResultFailure, error);
            
            goto cleanup;
        }
        
        if (self.patchInstallerRequirements) {
            NSString *randomFolderName = [NSString stringWithFormat:@"install-image-%@", [HelperFunctions randomStringWithLength:10]];
            
            // Defining the path to the temporary location for the Windows Install Image on the system drive.
            tempDirectory = [NSString pathWithComponents: @[
                [HelperFunctions applicationTempFolder],
                randomFolderName
            ]];
            
            CallbackHandlerWithCleanup(dwFile, 0, DWOperationTypeCreateDirectory, DWOperationResultStart, NULL);
            
            NSError *directoryCreateError = NULL;
            
            BOOL directoryCreatedSuccessfully = [localFileManager createDirectoryAtPath: tempDirectory
                                                            withIntermediateDirectories: YES
                                                                             attributes: NULL
                                                                                  error: &directoryCreateError];
            
            CallbackHandlerWithCleanup(dwFile, 0, DWOperationTypeCreateDirectory, (directoryCreatedSuccessfully ? DWOperationResultSuccess : DWOperationResultFailure), directoryCreateError);
            
            // We don't need to continue unless creating a directory wasn't successful. All further operations require a success from the previous operation.
            if (!directoryCreatedSuccessfully) {
                goto cleanup;
            }
            
            // Setting the location for Windows Install Image to the NSTemporaryDirectory(). (Example: /var/folders/b2/zvoxm8cn7995b9jnt2love090000gn/T/windiskwriter-ABCDEFGHI1/install.wim)
            sourcePath = [tempDirectory stringByAppendingPathComponent: sourcePath.lastPathComponent];
            
            __block DWAction latestAction = DWActionContinue;
            
            // Copying Windows Install File into a temporary directory
            BOOL copyWasSuccessfull = [self copyFileWithDWFile: dwFile
                                           destinationFilePath: sourcePath
                                                    bufferSize: COPY_BUFFER_SIZE
                                         ignoreFilesystemCheck: YES
                                                      callback:^DWAction(DWFile *dwFile, uint64 copiedBytes, DWOperationType operationType, DWOperationResult operationResult, NSError *error) {
                
                latestAction = callback(dwFile, copiedBytes, operationType, operationResult, error);
                
                return latestAction;
            }];
            
            // We don't need to continue unless copying wasn't successful. All further operations require a success from the previous operation.
            if (!copyWasSuccessfull) {
                goto cleanup;
            }
            
            // If we're running as root, we need to 'chmod 777' install.wim/.esd in order to be accepted by wimlib.
            if ([HelperFunctions hasElevatedRights]) {
                CallbackHandlerWithCleanup(dwFile, 0, DWOperationTypeSetFilePermissions, DWOperationResultStart, NULL);

                NSError *setAllPermissionsError = NULL;
                
                [HelperFunctions setAllPermissionsForPath: sourcePath
                                                    error: &setAllPermissionsError];
                
                CallbackHandlerWithCleanup(dwFile, 0, DWOperationTypeSetFilePermissions, (setAllPermissionsError == NULL ? DWOperationResultSuccess : DWOperationResultFailure), NULL);
                
                if (setAllPermissionsError != NULL) {
                    goto cleanup;
                }
            }
            
            if (latestAction == DWActionStop) {
                goto cleanup;
            }
        }
    }
    
    // Patching Windows Image Installer Requirements (Relevant primarily on Windows 11 and up)
    if (self.patchInstallerRequirements) {
        CallbackHandlerWithCleanup(dwFile, 0, DWOperationTypePatchWindowsInstallerRequirements, DWOperationResultStart, NULL);
        
        WimlibWrapper *wimlibWrapper = [[WimlibWrapper alloc] initWithWimPath:
                                            /* Choosing Windows Installer Image Path based on previous operations */
                                        tempDirectory != NULL ? sourcePath : destinationPath
        ];
        
        WimlibWrapperResult installerRequirementsPatchResult = [wimlibWrapper patchWindowsRequirementsChecks];
        
        DWOperationResult operationResult;
        switch (installerRequirementsPatchResult) {
            case WimlibWrapperResultSuccess:
                operationResult = DWOperationResultSuccess;
                break;
            case WimlibWrapperResultSkipped:
                operationResult = DWOperationResultSkipped;
                break;
            case WimlibWrapperResultFailure:
                operationResult = DWOperationResultFailure;
        }
        
        CallbackHandlerWithCleanup(dwFile, 0, DWOperationTypePatchWindowsInstallerRequirements, operationResult, NULL);
    }
    
    // Splitting install.wim file in order to fit into FAT32 partition
    if (requiresSplitting) {
        UInt8 partsCount = ceil((double)dwFile.size / (double)FAT32_MAX_FILE_SIZE);
        UInt64 maxSliceSize = dwFile.size / partsCount;
        
        CallbackHandlerWithCleanup(dwFile, 0, DWOperationTypeSplitWindowsImage, DWOperationResultStart, NULL);
        
        WimlibWrapper *wimlibWrapper = [[WimlibWrapper alloc] initWithWimPath: sourcePath];
        
        __block DWAction lastAction = DWActionContinue;
        
        __block BOOL isFirstCall = YES;
        WimlibWrapperResult splitImageResult = [wimlibWrapper splitWithDestinationDirectoryPath: [destinationPath stringByDeletingLastPathComponent]
                                                                            maxSliceSizeInBytes: maxSliceSize
                                                                                       callback: ^BOOL(uint32_t totalPartsCount, uint32 currentPartNumber, uint64 bytesWritten, uint64 bytesTotal) {
            
            if (isFirstCall) {
                [dwFile setSize:bytesTotal];
                
                isFirstCall = NO;
            }
            
            lastAction = callback(dwFile, bytesWritten, DWOperationTypeSplitWindowsImage, DWOperationResultProcess, NULL);
            
            return lastAction == DWActionContinue;
        }];
        
        if (lastAction != DWActionContinue) {
            goto cleanup;
        }
        
        DWOperationResult operationResult;
        switch (splitImageResult) {
            case WimlibWrapperResultSuccess:
                operationResult = DWOperationResultSuccess;
                break;
            case WimlibWrapperResultFailure:
                operationResult = DWOperationResultFailure;
                break;
            case WimlibWrapperResultSkipped:
                operationResult = DWOperationResultSkipped;
                break;
        }
        
        CallbackHandlerWithCleanup(dwFile, 0, DWOperationTypeSplitWindowsImage, operationResult, NULL);
    }
    
    operationWasSuccessful = YES;
    
cleanup: {
    BOOL wimLibTempDirectoryExists = [localFileManager fileExistsAtPath: tempDirectory];
    if (wimLibTempDirectoryExists) {
        [localFileManager removeItemAtPath: tempDirectory
                                     error: NULL];
    }
}
    return operationWasSuccessful;
}

- (BOOL)startWritingWithError: (NSError **)error
             progressCallback: (ChainedCallbackAction)progressCallback {
    
#define DWCallbackHandlerLoop(dwFile, writtenBytes, operationType, operationResult, error)    \
switch (progressCallback(dwFile, writtenBytes, operationType, operationResult, error)) {      \
case DWActionContinue:                                                                        \
break;                                                                                        \
case DWActionStop:                                                                            \
return NO;                                                                                    \
case DWActionSkip:                                                                            \
continue;                                                                                     \
case DWActionRetry:                                                                           \
break; /* retriable operations wrap their own retry loops */                                  \
}

if (![self commonErrorCheckerWithError:error]) {
    return NO;
}
    
    DWFile *installerWIMPackageFile = NULL;
    BOOL hasEFIBootloader = NO;
    
    for (DWFile *currentFile in [self.filesContainer files]) {
        @autoreleasepool {
            NSString *absoluteSourcePath = [self.filesContainer.containerPath stringByAppendingPathComponent:currentFile.sourcePath];
            NSString *absoluteDestinationPath = [_destinationPath stringByAppendingPathComponent:currentFile.sourcePath];
            
            NSString *lastPathComponent = [[[currentFile sourcePath] lastPathComponent] lowercaseString];
            
            // [Detected file type: Directory]
            if (currentFile.fileType == NSFileTypeDirectory) {
                DWCallbackHandlerLoop(currentFile, 0, DWOperationTypeCreateDirectory, DWOperationResultStart, NULL);
                
                NSError *createDirectoryError = NULL;
                BOOL directoryCreateSuccess = [localFileManager createDirectoryAtPath: absoluteDestinationPath
                                                          withIntermediateDirectories: YES
                                                                           attributes: NULL
                                                                                error: &createDirectoryError];
                
                DWCallbackHandlerLoop(currentFile, 0, DWOperationTypeCreateDirectory, (directoryCreateSuccess ? DWOperationResultSuccess : DWOperationResultFailure), createDirectoryError);
                
                continue;
            }
            
            // [Detected file type: Windows Install Image]
            if ([lastPathComponent hasOneOfTheSuffixes:@[@"install.wim", @"install.esd"]]) {
                // We save the location of the Windows Install Image file for possible extraction of the EFI bootloader from it (if initially absent)
                installerWIMPackageFile = currentFile;
                
                __block DWAction lastAction = DWActionContinue;

                do {
                    [self writeWindowsInstallWithDWFile: currentFile
                                        destinationPath: absoluteDestinationPath
                                               callback: ^DWAction(DWFile * _Nonnull dwFile, uint64 copiedBytes, DWOperationType operationType, DWOperationResult operationResult, NSError * _Nonnull error) {

                        lastAction = progressCallback(dwFile, copiedBytes, operationType, operationResult, error);

                        return lastAction;
                    }];
                } while (lastAction == DWActionRetry);

                if (lastAction == DWActionStop) {
                    return NO;
                }
                
                continue;
            }
            
            // [Detected file type: Regular File]
            {
                // Check if there is a Windows bootloader for UEFI systems in the operating system files. (If it is missing, then later we will try to extract it from Install[.wim/.esd])
                NSString *relativeSourcePathLowercase = currentFile.sourcePath.lowercaseString;
                if (!hasEFIBootloader && [relativeSourcePathLowercase hasPrefix:@"efi/boot/boot"] && [relativeSourcePathLowercase.lastPathComponent hasSuffix:@".efi"]) {
                    hasEFIBootloader = YES;
                }
                
                __block DWAction lastAction = DWActionContinue;

                BOOL copyingWasSuccessfull = NO;

                do {
                    copyingWasSuccessfull = [self copyFileWithDWFile: currentFile
                                                  destinationFilePath: absoluteDestinationPath
                                                           bufferSize: COPY_BUFFER_SIZE
                                                ignoreFilesystemCheck: NO
                                                             callback: ^DWAction(DWFile * _Nonnull dwFile, uint64 copiedBytes, DWOperationType operationType, DWOperationResult operationResult, NSError * _Nonnull error) {

                        lastAction = progressCallback(dwFile, copiedBytes, operationType, operationResult, error);

                        return lastAction;
                    }];
                } while (lastAction == DWActionRetry);

                if (lastAction == DWActionStop) {
                    return NO;
                }
                
                continue;
            }
        }
    }

    // Fix for TechUnRestricted/windiskwriter#75 and #29: verify the written files
    // after the copy loop, so an unexpected disconnect or a read-only mount
    // surfaces as a verification failure instead of a silently broken installer.
    // All file sizes are checked, plus the install image (or the largest file)
    // gets a full SHA-256 comparison.
    DWFile *verificationAnchorFile = self.filesContainer.files.firstObject;

    if (verificationAnchorFile != NULL) {
        // Note: the size sweep is instant, but the final hash comparison cannot
        // be interrupted — worst case it delays a Stop request by one file hash.
        BOOL verificationRetryRequested = NO;

        do {
            verificationRetryRequested = NO;

            switch (progressCallback(verificationAnchorFile, 0, DWOperationTypeVerifyWrittenFiles, DWOperationResultStart, NULL)) {
                case DWActionStop:
                    return NO;
                case DWActionSkip:
                case DWActionContinue:
                case DWActionRetry:
                    break;
            }

            BOOL verificationPassed = YES;
            NSError *verificationError = NULL;
            DWFile *hashCheckFile = installerWIMPackageFile;

            for (DWFile *currentFile in [self.filesContainer files]) {
                // A directory has no meaningful "size": it differs between the
                // source filesystem (UDF/ISO) and FAT32, and says nothing about
                // whether its contents were written correctly.
                if (currentFile.fileType == NSFileTypeDirectory) {
                    continue;
                }

                // The patched boot.wim intentionally diverges from the source image
                // (Autounattend.xml injected), so source-based checks do not apply.
                if (self.patchInstallerRequirements && [currentFile.sourcePath.lowercaseString isEqualToString: @"sources/boot.wim"]) {
                    continue;
                }

                NSString *absoluteDestinationFilePath = [self.destinationPath stringByAppendingPathComponent: currentFile.sourcePath];
                NSDictionary *destinationFileAttributes = [localFileManager attributesOfItemAtPath: absoluteDestinationFilePath
                                                                                             error: NULL];

                if (destinationFileAttributes == NULL || destinationFileAttributes.fileSize != currentFile.size) {
                    verificationPassed = NO;
                    verificationError = [NSError errorWithStringValue: [LocalizedStrings errorTextWrittenFileVerificationFailureWithArgument1: currentFile.sourcePath]];

                    break;
                }

                if (hashCheckFile == NULL || currentFile.size > hashCheckFile.size) {
                    hashCheckFile = currentFile;
                }
            }

            if (verificationPassed && hashCheckFile != NULL) {
                NSString *sourceHash = [HelperFunctions sha256ForFileAtPath: [self.filesContainer.containerPath stringByAppendingPathComponent: hashCheckFile.sourcePath]];
                NSString *destinationHash = [HelperFunctions sha256ForFileAtPath: [self.destinationPath stringByAppendingPathComponent: hashCheckFile.sourcePath]];

                if (sourceHash == NULL || destinationHash == NULL || ![sourceHash isEqualToString: destinationHash]) {
                    verificationPassed = NO;
                    verificationError = [NSError errorWithStringValue: [LocalizedStrings errorTextWrittenFileVerificationFailureWithArgument1: hashCheckFile.sourcePath]];
                }
            }

            switch (progressCallback(verificationAnchorFile, 0, DWOperationTypeVerifyWrittenFiles, (verificationPassed ? DWOperationResultSuccess : DWOperationResultFailure), verificationError)) {
                case DWActionStop:
                    return NO;
                case DWActionRetry:
                    verificationRetryRequested = YES;
                    break;
                case DWActionSkip:
                case DWActionContinue:
                    break;
            }
        } while (verificationRetryRequested);
    }
    // Fix for TechUnRestricted/windiskwriter#64 and #2: an ei.cfg with an empty
    // EditionID makes Windows Setup show the edition picker instead of silently
    // installing the edition hardcoded in the ACPI SLIC table of the target PC.
    if (self.addEiCfgFile) {
        NSString *sourcesDirectoryPath = [self.destinationPath stringByAppendingPathComponent: @"sources"];

        if ([localFileManager fileExistsAtPath: sourcesDirectoryPath]) {
            NSString *eiCfgFilePath = [sourcesDirectoryPath stringByAppendingPathComponent: @"ei.cfg"];
            NSString *eiCfgContent = @"[EditionID]\n\n[Channel]\nRetail\n";

            [eiCfgContent writeToFile: eiCfgFilePath
                           atomically: YES
                            encoding: NSUTF8StringEncoding
                               error: NULL];
        }
    }

    // Fix for TechUnRestricted/windiskwriter#1: launch the local account dialog
    // during OOBE (the current replacement for the retired OOBE\BYPASSNRO —
    // ms-cxh:localonly opens the offline account creation form directly).
    // Components for both architectures are included so the file works on
    // x64 and ARM64 media alike; on Windows 10 the command is a harmless no-op.
    if (self.addUnattendFile) {
        NSString *unattendContent = @"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        @"<unattend xmlns=\"urn:schemas-microsoft-com:unattend\"\n"
        @"          xmlns:wcm=\"http://schemas.microsoft.com/WMIConfig/2002/State\">\n"
        @"    <settings pass=\"oobeSystem\">\n"
        @"        <component name=\"Microsoft-Windows-Deployment\" processorArchitecture=\"amd64\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\">\n"
        @"            <RunSynchronous>\n"
        @"                <RunSynchronousCommand wcm:action=\"add\">\n"
        @"                    <Order>1</Order>\n"
        @"                    <Description>Offer local account creation</Description>\n"
        @"                    <CommandLine>start ms-cxh:localonly</CommandLine>\n"
        @"                </RunSynchronousCommand>\n"
        @"            </RunSynchronous>\n"
        @"        </component>\n"
        @"        <component name=\"Microsoft-Windows-Deployment\" processorArchitecture=\"arm64\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\">\n"
        @"            <RunSynchronous>\n"
        @"                <RunSynchronousCommand wcm:action=\"add\">\n"
        @"                    <Order>1</Order>\n"
        @"                    <Description>Offer local account creation</Description>\n"
        @"                    <CommandLine>start ms-cxh:localonly</CommandLine>\n"
        @"                </RunSynchronousCommand>\n"
        @"            </RunSynchronous>\n"
        @"        </component>\n"
        @"    </settings>\n"
        @"</unattend>\n";

        [unattendContent writeToFile: [self.destinationPath stringByAppendingPathComponent: @"autounattend.xml"]
                          atomically: YES
                           encoding: NSUTF8StringEncoding
                              error: NULL];
    }

    // Trying to extract a bootloader for (x86_64 systems only. There is no need to check for x86 or ARM binaries.)
    if (installerWIMPackageFile && !hasEFIBootloader) {
        // Sadly, there is no way we can do it better without creating another macro
        switch (progressCallback(installerWIMPackageFile, 0, DWOperationTypeExtractWindowsBootloader, DWOperationResultStart, NULL)) {
            case DWActionContinue:
                break;
            case DWActionSkip:
                goto postBootloaderExtract;
            case DWActionStop:
                return NO;
        }
        
        NSString *installImageAbsolutePath = [self.filesContainer.containerPath stringByAppendingPathComponent: installerWIMPackageFile.sourcePath];
        
        NSString *extractedEFIBootloaderDestinationDirectory = [self.destinationPath stringByAppendingPathComponent: @"efi/boot/"];
        
        WimlibWrapper *wimlibWrapper = [[WimlibWrapper alloc] initWithWimPath:installImageAbsolutePath];
        WimlibWrapperResult wimlibWrapperExtractionResult = [wimlibWrapper extractWindowsEFIBootloaderForDestinationDirectory:extractedEFIBootloaderDestinationDirectory];
        
        DWOperationResult operationResult;
        switch (wimlibWrapperExtractionResult) {
            case WimlibWrapperResultSuccess:
                operationResult = DWOperationResultSuccess;
                break;
            case WimlibWrapperResultFailure:
                operationResult = DWOperationResultFailure;
                break;
            case WimlibWrapperResultSkipped:
                operationResult = DWOperationResultSkipped;
                break;
        }
        
        switch (progressCallback(installerWIMPackageFile, 0, DWOperationTypeExtractWindowsBootloader, operationResult, NULL)) {
            case DWActionContinue:
                break;
            case DWActionSkip:
                goto postBootloaderExtract;
            case DWActionStop:
                return NO;
        }
    }
    
postBootloaderExtract:
    
    if (self.installLegacyBoot) {
        DWFile *legacyBootloaderDWFile = [[DWFile alloc] initWithSourcePath: @"[Legacy Bootloader]"];
        
        switch (progressCallback(legacyBootloaderDWFile, 0, DWOperationTypeInstallLegacyBootSector, DWOperationResultStart, NULL)) {
            case DWActionContinue:
                break;
            case DWActionSkip:
                goto postLegacyBootloaderInstall;
            case DWActionStop:
                return NO;
        }
        
        NSError *installLegacyBootError = NULL;
        
        BOOL installLegacyBootResult = [self writeLegacyBootSectorWithError: &installLegacyBootError];
        
        progressCallback(legacyBootloaderDWFile, 0, DWOperationTypeInstallLegacyBootSector, (installLegacyBootError == NULL) ? DWOperationResultSuccess : DWOperationResultFailure, installLegacyBootError);
        
        if (!installLegacyBootResult) {
            // We don't need to continue since it's the last step
            return NO;
        }
    }
    
postLegacyBootloaderInstall:
    
    return YES;
}

- (BOOL)commonErrorCheckerWithError: (NSError *_Nonnull *_Nonnull)error {
    if (![localFileManager folderExistsAtPath: _destinationPath]) {
        *error = [NSError errorWithStringValue: [LocalizedStrings errorTextDestinationPathDoesNotExist]];
        
        return NO;
    }
    
    UInt64 sizeOfSourceFiles = [_filesContainer sizeOfFiles];
    
    NSError *destinationGetDiskAvailableSpaceError = NULL;
    UInt64 destinationDiskAvailableSpace = [self destinationDiskFreeSpace];
    
    if (destinationDiskAvailableSpace == 0) {
        *error = [NSError errorWithStringValue: [LocalizedStrings errorTextGetAvailableDestinationDiskSpaceFailure]];
        
        return NO;
    }
    
    if (sizeOfSourceFiles > destinationDiskAvailableSpace) {
        *error = [NSError errorWithStringValue: [LocalizedStrings errorTextSourceIsTooLargeForTheDestinationDisk]];
        
        return NO;
    }
    
    return YES;
}

- (UInt64)destinationDiskFreeSpace {
    NSDictionary *filesystemAttributes = [localFileManager attributesOfFileSystemForPath: _destinationPath
                                                                                   error: NULL];
    
    return [[filesystemAttributes objectForKey: NSFileSystemFreeSize] longLongValue];
}

// Fix for TechUnRestricted/windiskwriter#61: non-Windows bootable images
// (Linux ISOs and the like) cannot be written through the FAT32 file-copy
// pipeline — they expect the whole image to land on the device byte-for-byte,
// so the write goes straight to the raw BSD device instead.
+ (BOOL)rawWriteImageFileAtPath: (NSString *)imagePath
                    toBSDDevice: (NSString *)bsdName
                       callback: (ChainedCallbackAction)callback
                          error: (NSError *_Nullable *_Nullable)error {
    // Nothing may hold the volumes we are about to overwrite.
    [CommandLine execute: @"/usr/sbin/diskutil"
               arguments: @[@"unmountDisk", @"force", bsdName]
               exception: NULL];

    NSString *rawDevicePath = [@"/dev/r" stringByAppendingString: bsdName];

    FILE *source = fopen([imagePath UTF8String], "rb");
    if (source == NULL) {
        if (error) {
            *error = [NSError errorWithStringValue: [LocalizedStrings errorTextOpenSourceFileFailure]];
        }

        return NO;
    }

    FILE *destination = fopen([rawDevicePath UTF8String], "wb");
    if (destination == NULL) {
        fclose(source);

        if (error) {
            *error = [NSError errorWithStringValue: [LocalizedStrings errorTextOpenDestinationPathFailure]];
        }

        return NO;
    }

    DWFile *imageFile = [[DWFile alloc] initWithSourcePath: imagePath];
    fseek(source, 0, SEEK_END);
    imageFile.size = ftell(source);
    fseek(source, 0, SEEK_SET);

    callback(imageFile, 0, DWOperationTypeWriteRawImage, DWOperationResultStart, NULL);

    void *buffer = malloc(COPY_BUFFER_SIZE);
    if (buffer == NULL) {
        fclose(source);
        fclose(destination);

        NSError *localError = [NSError errorWithStringValue: [LocalizedStrings errorTextAllocateMemoryBufferFailure]];
        callback(imageFile, 0, DWOperationTypeWriteRawImage, DWOperationResultFailure, localError);

        if (error) {
            *error = localError;
        }

        return NO;
    }

    uint64_t bytesWritten = 0;

    while (true) {
        size_t readSize = fread(buffer, 1, COPY_BUFFER_SIZE, source);
        if (readSize == 0) {
            break;
        }

        size_t writeSize = fwrite(buffer, 1, readSize, destination);
        bytesWritten += writeSize;

        DWAction action = callback(imageFile, bytesWritten, DWOperationTypeWriteRawImage, DWOperationResultProcess, NULL);

        // There is nothing to "skip" in a raw stream — Stop and Skip both abort.
        if (action != DWActionContinue) {
            free(buffer);
            fclose(source);
            fclose(destination);

            return NO;
        }

        if (writeSize != readSize) {
            free(buffer);
            fclose(source);
            fclose(destination);

            NSError *localError = [NSError errorWithStringValue: [LocalizedStrings errorTextWriteDestinationPathDataFailure]];
            callback(imageFile, bytesWritten, DWOperationTypeWriteRawImage, DWOperationResultFailure, localError);

            if (error) {
                *error = localError;
            }

            return NO;
        }
    }

    free(buffer);

    // Make sure the OS pushes everything to the device before declaring victory.
    fflush(destination);
    fsync(fileno(destination));

    // Fix for TechUnRestricted/windiskwriter#75: raw writes have no per-file
    // verification trail. Compare the first and last megabyte instead — that is
    // where boot-breaking truncation or stale device content shows up, and it
    // costs a couple of megabytes of reads instead of re-reading the whole drive.
    {
        const uint64_t edgeVerifySize = 1024 * 1024;
        uint64_t compareSize = imageFile.size < edgeVerifySize ? imageFile.size : edgeVerifySize;
        BOOL edgesVerified = YES;
        NSError *verifyError = NULL;

        void *sourceEdge = malloc(compareSize);
        void *deviceEdge = malloc(compareSize);

        if (sourceEdge == NULL || deviceEdge == NULL) {
            free(sourceEdge);
            free(deviceEdge);
            edgesVerified = NO;
            verifyError = [NSError errorWithStringValue: [LocalizedStrings errorTextAllocateMemoryBufferFailure]];
        }

        if (edgesVerified) {
            // Head of the image.
            fseek(source, 0, SEEK_SET);
            fseek(destination, 0, SEEK_SET);

            if (fread(sourceEdge, 1, compareSize, source) != compareSize ||
                fread(deviceEdge, 1, compareSize, destination) != compareSize ||
                memcmp(sourceEdge, deviceEdge, compareSize) != 0) {
                edgesVerified = NO;
                verifyError = [NSError errorWithStringValue: [LocalizedStrings errorTextRawWriteVerificationFailure]];
            }
        }

        if (edgesVerified && imageFile.size > compareSize) {
            // Tail of the image.
            fseek(source, (long)(imageFile.size - compareSize), SEEK_SET);
            fseek(destination, (long)(imageFile.size - compareSize), SEEK_SET);

            if (fread(sourceEdge, 1, compareSize, source) != compareSize ||
                fread(deviceEdge, 1, compareSize, destination) != compareSize ||
                memcmp(sourceEdge, deviceEdge, compareSize) != 0) {
                edgesVerified = NO;
                verifyError = [NSError errorWithStringValue: [LocalizedStrings errorTextRawWriteVerificationFailure]];
            }
        }

        free(sourceEdge);
        free(deviceEdge);

        if (!edgesVerified) {
            fclose(source);
            fclose(destination);

            callback(imageFile, bytesWritten, DWOperationTypeWriteRawImage, DWOperationResultFailure, verifyError);

            if (error) {
                *error = verifyError;
            }

            return NO;
        }
    }

    fclose(source);
    fclose(destination);

    callback(imageFile, bytesWritten, DWOperationTypeWriteRawImage, DWOperationResultSuccess, NULL);

    return YES;
}

// Builds the Autounattend.xml injected into sources/boot.wim. Components are
// emitted for both amd64 and arm64 so one file serves either installation.
// Sections mirror the hardware-check bypasses (windowsPE LabConfig reg-adds)
// and the privacy / device-encryption toggles (oobeSystem).
+ (NSString *)autounattendXMLWithHardwareBypass: (BOOL)hardwareBypass
                                   disableBitLocker: (BOOL)disableBitLocker
                              disableDataCollection: (BOOL)disableDataCollection {
    if (!hardwareBypass && !disableBitLocker && !disableDataCollection) {
        return NULL;
    }

    NSMutableString *xml = [NSMutableString stringWithString:
        @"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        @"<unattend xmlns=\"urn:schemas-microsoft-com:unattend\">\n"];

    if (hardwareBypass) {
        [xml appendString: @"  <settings pass=\"windowsPE\">\n"];

        for (NSString *architecture in @[@"amd64", @"arm64"]) {
            [xml appendFormat:
                @"    <component name=\"Microsoft-Windows-Setup\" processorArchitecture=\"%@\" language=\"neutral\" "
                @"xmlns:wcm=\"http://schemas.microsoft.com/WMIConfig/2002/State\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" "
                @"publicKeyToken=\"31bf3856ad364e35\" versionScope=\"nonSxS\">\n", architecture];
            [xml appendString:
                @"      <UserData>\n"
                @"        <AcceptEula>true</AcceptEula>\n"
                @"        <ProductKey>\n"
                @"          <Key />\n"
                @"        </ProductKey>\n"
                @"      </UserData>\n"
                @"      <RunSynchronous>\n"];

            NSDictionary *bypassOrder = @{@1: @"BypassTPMCheck", @2: @"BypassSecureBootCheck", @3: @"BypassRAMCheck", @4: @"BypassCPUCheck", @5: @"BypassStorageCheck"};
            for (NSNumber *order in bypassOrder) {
                [xml appendFormat:
                    @"        <RunSynchronousCommand wcm:action=\"add\">\n"
                    @"          <Order>%@</Order>\n"
                    @"          <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v %@ /t REG_DWORD /d 1 /f</Path>\n"
                    @"        </RunSynchronousCommand>\n", order, bypassOrder[order]];
            }

            [xml appendString:
                @"      </RunSynchronous>\n"
                @"    </component>\n"];
        }

        [xml appendString: @"  </settings>\n"];
    }

    if (disableBitLocker || disableDataCollection) {
        [xml appendString: @"  <settings pass=\"oobeSystem\">\n"];

        for (NSString *architecture in @[@"amd64", @"arm64"]) {
            NSString *componentHeaderFormat =
                @"    <component name=\"%@\" processorArchitecture=\"%@\" language=\"neutral\" "
                @"xmlns:wcm=\"http://schemas.microsoft.com/WMIConfig/2002/State\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" "
                @"publicKeyToken=\"31bf3856ad364e35\" versionScope=\"nonSxS\">\n";

            if (disableDataCollection) {
                [xml appendFormat: componentHeaderFormat, @"Microsoft-Windows-Shell-Setup", architecture];
                [xml appendString:
                    @"      <OOBE>\n"
                    @"        <HideEULAPage>true</HideEULAPage>\n"
                    @"        <ProtectYourPC>3</ProtectYourPC>\n"
                    @"      </OOBE>\n"
                    @"    </component>\n"];
            }

            if (disableBitLocker) {
                [xml appendFormat: componentHeaderFormat, @"Microsoft-Windows-SecureStartup-FilterDriver", architecture];
                [xml appendString:
                    @"      <PreventDeviceEncryption>true</PreventDeviceEncryption>\n"
                    @"    </component>\n"];

                [xml appendFormat: componentHeaderFormat, @"Microsoft-Windows-EnhancedStorage-Adm", architecture];
                [xml appendString:
                    @"      <TCGSecurityActivationDisabled>1</TCGSecurityActivationDisabled>\n"
                    @"    </component>\n"];
            }
        }

        [xml appendString: @"  </settings>\n"];
    }

    [xml appendString: @"</unattend>\n"];

    return xml;
}

@end
