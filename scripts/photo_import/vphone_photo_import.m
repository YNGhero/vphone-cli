#import <Foundation/Foundation.h>
#import <Photos/Photos.h>

static void usage(const char *argv0) {
    fprintf(stderr, "usage: %s /path/to/image [album]\n", argv0);
}

static BOOL ensurePhotoAuthorization(void) {
    if (@available(iOS 14.0, *)) {
        PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
        if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
            return YES;
        }
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block PHAuthorizationStatus requested = status;
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus s) {
            requested = s;
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        return requested == PHAuthorizationStatusAuthorized || requested == PHAuthorizationStatusLimited;
    }

    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
    if (status == PHAuthorizationStatusAuthorized) {
        return YES;
    }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block PHAuthorizationStatus requested = status;
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus s) {
        requested = s;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    return requested == PHAuthorizationStatusAuthorized;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            usage(argv[0]);
            return 2;
        }

        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSString *albumName = argc >= 3 ? [NSString stringWithUTF8String:argv[2]] : nil;
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            fprintf(stderr, "file not found: %s\n", path.UTF8String);
            return 3;
        }

        if (!ensurePhotoAuthorization()) {
            fprintf(stderr, "PhotoKit authorization denied or unavailable\n");
            return 4;
        }

        NSURL *url = [NSURL fileURLWithPath:path];
        __block NSString *localId = nil;
        NSError *err = nil;
        BOOL ok = [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
            PHAssetCreationRequest *assetReq = [PHAssetCreationRequest creationRequestForAsset];
            PHAssetResourceCreationOptions *opts = [PHAssetResourceCreationOptions new];
            opts.shouldMoveFile = NO;
            [assetReq addResourceWithType:PHAssetResourceTypePhoto fileURL:url options:opts];

            PHObjectPlaceholder *assetPlaceholder = assetReq.placeholderForCreatedAsset;
            localId = assetPlaceholder.localIdentifier;

            if (albumName.length > 0 && assetPlaceholder) {
                PHFetchResult<PHAssetCollection *> *collections = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum subtype:PHAssetCollectionSubtypeAny options:nil];
                __block PHAssetCollection *target = nil;
                [collections enumerateObjectsUsingBlock:^(PHAssetCollection *obj, NSUInteger idx, BOOL *stop) {
                    if ([obj.localizedTitle isEqualToString:albumName]) {
                        target = obj;
                        *stop = YES;
                    }
                }];

                PHAssetCollectionChangeRequest *albumReq = nil;
                if (target) {
                    albumReq = [PHAssetCollectionChangeRequest changeRequestForAssetCollection:target];
                } else {
                    albumReq = [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:albumName];
                }
                [albumReq addAssets:@[assetPlaceholder]];
            }
        } error:&err];

        if (!ok) {
            fprintf(stderr, "PhotoKit import failed: %s\n", err.localizedDescription.UTF8String ?: "unknown");
            if (err) {
                fprintf(stderr, "domain=%s code=%ld\n", err.domain.UTF8String, (long)err.code);
            }
            return 1;
        }

        printf("OK imported %s\n", localId.UTF8String ?: "");
        return 0;
    }
}
