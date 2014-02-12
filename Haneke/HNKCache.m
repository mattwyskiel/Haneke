//
//  HNKCache.m
//  Haneke
//
//  Created by Hermes on 10/02/14.
//  Copyright (c) 2014 Hermes Pique. All rights reserved.
//

#import "HNKCache.h"

@interface UIImage (hnk_utils)

- (CGSize)hnk_aspectFillSizeForSize:(CGSize)size;
- (CGSize)hnk_aspectFitSizeForSize:(CGSize)size;
- (UIImage *)hnk_imageByScalingToSize:(CGSize)newSize;

@end

@interface HNKCacheFormat()

@property (nonatomic, assign) unsigned long long diskSize;
@property (nonatomic, weak) HNKCache *cache;
@property (nonatomic, readonly) NSString *directory;

@end

@interface HNKCache()

@property (nonatomic, readonly) NSString *rootDirectory;

@end


@implementation HNKCache {
    NSMutableDictionary *_memoryCaches;
    NSMutableDictionary *_formats;
    NSString *_rootDirectory;
    dispatch_queue_t _diskQueue;
}

#pragma mark Initializing the cache

- (id)initWithName:(NSString*)name
{
    self = [super init];
    if (self)
    {
        _memoryCaches = [NSMutableDictionary dictionary];
        _formats = [NSMutableDictionary dictionary];

        NSString *cachesDirectory = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        static NSString *cachePathComponent = @"com.hpique.haneke";
        NSString *path = [cachesDirectory stringByAppendingPathComponent:cachePathComponent];
        _rootDirectory = [path stringByAppendingPathComponent:name];
        _diskQueue = dispatch_queue_create("com.hpique.haneke.disk", NULL);
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
}

+ (HNKCache*)sharedCache
{
    static HNKCache *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[HNKCache alloc] initWithName:@"shared"];
    });
    return instance;
}

- (void)registerFormat:(HNKCacheFormat *)format
{
    if (_formats[format.name])
    {
        [self clearFormatNamed:format.name];
    }
    _formats[format.name] = format;
    format.cache = self;
    dispatch_async(_diskQueue, ^{
        [self calculateDiskSizeOfFormat:format];
        [self controlDiskCapacityOfFormat:format];
    });
}

- (NSDictionary*)formats
{
    return _formats.copy;
}

#pragma mark Getting images

- (UIImage*)imageForEntity:(id<HNKCacheEntity>)entity formatName:(NSString *)formatName
{
    HNKCacheFormat *format = _formats[formatName];
    NSAssert(format, @"Unknown format %@", formatName);
    
    NSString *entityId = entity.cacheId;
    UIImage *image = [self imageForEntityId:entityId format:format];
    if (image)
    {
        dispatch_async(_diskQueue, ^{
            [self updateAccessDateOfImage:image entityId:entityId format:format];
        });
        return image;
    }

    NSString *path = [self pathForEntityId:entityId format:format];
    __block NSData *imageData;
    dispatch_sync(_diskQueue, ^{
        imageData = [NSData dataWithContentsOfFile:path];
    });
    if (imageData)
    {
        image = [UIImage imageWithData:imageData scale:[UIScreen mainScreen].scale]; // Do not use imageWithContentsOfFile: as it doesn't consider scale
        if (image)
        {
            dispatch_async(_diskQueue, ^{
                [self updateAccessDateOfImage:image entityId:entityId format:format];
            });
            [self setImage:image forEntityId:entityId format:format];
            return image;
        }
    }

    UIImage *originalImage = entity.cacheOriginalImage;
    if (!originalImage)
    {
        NSData *originalData = entity.cacheOriginalData;
        originalImage = [UIImage imageWithData:originalData scale:[UIScreen mainScreen].scale];
    }
    image = [format resizedImageFromImage:originalImage];
    [self setImage:image forEntityId:entityId format:format];
    dispatch_async(_diskQueue, ^{
        [self saveImage:image entityId:entityId format:format];
    });
    return image;
}

- (BOOL)retrieveImageForEntity:(id<HNKCacheEntity>)entity formatName:(NSString *)formatName completionBlock:(void(^)(id<HNKCacheEntity> entity, NSString *format, UIImage *image))completionBlock
{
    NSString *entityId = entity.cacheId;
    return [self retrieveImageFromCacheWithId:entityId formatName:formatName completionBlock:^(NSString *cacheId, NSString *formatName, UIImage *image) {
        if (image)
        {
            completionBlock(entity, formatName, image);
            return;
        }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            HNKCacheFormat *format = _formats[formatName];
            __block UIImage *originalImage = nil;
            dispatch_sync(dispatch_get_main_queue(), ^{
                originalImage = entity.cacheOriginalImage;
            });
            if (!originalImage)
            {
                __block NSData *originalData = nil;
                dispatch_sync(dispatch_get_main_queue(), ^{
                    originalData = entity.cacheOriginalData;
                });
                originalImage = [UIImage imageWithData:originalData scale:[UIScreen mainScreen].scale];
            }
            UIImage *image = [format resizedImageFromImage:originalImage];
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self setImage:image forEntityId:entityId format:format];
            });
            dispatch_sync(dispatch_get_main_queue(), ^{
                completionBlock(entity, formatName, image);
            });
            dispatch_sync(_diskQueue, ^{
                [self saveImage:image entityId:entityId format:format];
            });
        });
    }];
}

- (BOOL)retrieveImageFromCacheWithId:(NSString*)cacheId formatName:(NSString *)formatName completionBlock:(void(^)(NSString *cacheId, NSString *formatName, UIImage *image))completionBlock
{
    HNKCacheFormat *format = _formats[formatName];
    NSAssert(format, @"Unknown format %@", formatName);
    
    UIImage *image = [self imageForEntityId:cacheId format:format];
    if (image)
    {
        completionBlock(cacheId, formatName, image);
        dispatch_async(_diskQueue, ^{
            [self updateAccessDateOfImage:image entityId:cacheId format:format];
        });
        return YES;
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *path = [self pathForEntityId:cacheId format:format];
        __block NSData *imageData;
        dispatch_sync(_diskQueue, ^{
            imageData = [NSData dataWithContentsOfFile:path];
        });
        UIImage *image;
        if (imageData && (image = [UIImage imageWithData:imageData scale:[UIScreen mainScreen].scale]))
        {
            dispatch_sync(dispatch_get_main_queue(), ^{
                completionBlock(cacheId, formatName, image);
            });
            [self setImage:image forEntityId:cacheId format:format];
            dispatch_sync(_diskQueue, ^{
                [self updateAccessDateOfImage:image entityId:cacheId format:format];
            });
        }
        else
        {
            dispatch_sync(dispatch_get_main_queue(), ^{
                completionBlock(cacheId, formatName, nil);
            });
        }
    });
    return NO;
}

#pragma mark Removing images

- (void)clearFormatNamed:(NSString*)formatName
{
    HNKCacheFormat *format = _formats[formatName];
    NSCache *cache = [_memoryCaches objectForKey:formatName];
    [cache removeAllObjects];
    NSString *directory = format.directory;
    dispatch_async(_diskQueue, ^{
        NSError *error;
        if ([[NSFileManager defaultManager] removeItemAtPath:directory error:&error])
        {
            format.diskSize = 0;
        }
        else
        {
            BOOL isDirectory = NO;
            if (![[NSFileManager defaultManager] fileExistsAtPath:directory isDirectory:&isDirectory])
            {
                format.diskSize = 0;
            }
            else
            {
                NSLog(@"Failed to remove directory with error %@", error);
            }
        }
    });
}

- (void)removeImagesOfEntity:(id<HNKCacheEntity>)entity
{
    NSString *entityId = entity.cacheId;
    [_memoryCaches enumerateKeysAndObjectsUsingBlock:^(id key, NSCache *cache, BOOL *stop) {
        [cache removeObjectForKey:entityId];
    }];
    dispatch_async(_diskQueue, ^{
        NSDictionary *formats = _formats.copy;
        [formats enumerateKeysAndObjectsUsingBlock:^(id key, HNKCacheFormat *format, BOOL *stop) {
            NSString *path = [self pathForEntityId:entityId format:format];
            [self removeFileAtPath:path format:format];
        }];
    });
}

#pragma mark Private (utils)

- (NSString*)pathForEntityId:(NSString*)entityId format:(HNKCacheFormat*)format
{
    NSString *escapedEntityId = [entityId stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    NSString *path = [format.directory stringByAppendingPathComponent:escapedEntityId];
    return path;
}

#pragma mark Private (memory)

- (UIImage*)imageForEntityId:(NSString*)entityId format:(HNKCacheFormat*)format
{
    NSString *key = format.name;
    NSCache *cache = [_memoryCaches objectForKey:key];
    return [cache objectForKey:entityId];
}

- (void)setImage:(UIImage*)image forEntityId:(NSString*)entityId format:(HNKCacheFormat*)format
{
    NSString *key = format.name;
    NSCache *cache = _memoryCaches[key];
    if (!cache)
    {
        cache = [[NSCache alloc] init];
        _memoryCaches[key] = cache;
    }
    return [cache setObject:image forKey:entityId];
}

#pragma mark Private (disk)

- (void)calculateDiskSizeOfFormat:(HNKCacheFormat*)format
{
    NSString *directory = format.directory;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    format.diskSize = 0;
    NSError *error;
    NSArray *contents = [fileManager contentsOfDirectoryAtPath:directory error:&error];
    if (!contents)
    {
        NSLog(@"Failed to list directory with error %@", error);
        return;
    }
    for (NSString *pathComponent in contents)
    {
        NSString *path = [directory stringByAppendingPathComponent:pathComponent];
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:&error];
        if (!attributes) continue;
        
        format.diskSize += attributes.fileSize;
    }
}

- (void)controlDiskCapacityOfFormat:(HNKCacheFormat*)format
{
    if (format.diskSize <= format.diskCapacity) return;
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error;
    NSURL *directoryURL = [NSURL fileURLWithPath:format.directory];
    
    NSArray *contents = [fileManager contentsOfDirectoryAtURL:directoryURL includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:kNilOptions error:&error];
    if (!contents)
    {
        NSLog(@"Failed to list directory with error %@", error);
        return;
    }
    contents = [contents sortedArrayUsingComparator:^NSComparisonResult(NSURL *url1, NSURL *url2) {
        NSDate *date1;
        [url1 getResourceValue:&date1 forKey:NSURLContentModificationDateKey error:nil];
        NSDate *date2;
        [url2 getResourceValue:&date2 forKey:NSURLContentModificationDateKey error:nil] ;
        return [date1 compare:date2];
    }];
    [contents enumerateObjectsUsingBlock:^(NSURL *url, NSUInteger idx, BOOL *stop) {
        NSString *path = url.path;
        [self removeFileAtPath:path format:format];
        if (format.diskSize <= format.diskCapacity)
        {
            *stop = YES;
        }
    }];
}

- (void)removeFileAtPath:(NSString*)path format:(HNKCacheFormat*)format
{
    NSError *error;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:&error];
    if (attributes)
    {
        unsigned long long fileSize = attributes.fileSize;
        if ([fileManager removeItemAtPath:path error:&error])
        {
            format.diskSize -= fileSize;
        }
        else
        {
            NSLog(@"Failed to remove file with error %@", error);
        }
    }
}

- (void)saveImage:(UIImage*)image entityId:(NSString*)entityId format:(HNKCacheFormat*)format
{
    if (format.diskCapacity == 0) return;
    
    NSData *resizedImageData = UIImageJPEGRepresentation(image, format.compressionQuality);
    NSString *path = [self pathForEntityId:entityId format:format];
    NSError *error;
    if (![resizedImageData writeToFile:path options:kNilOptions error:&error])
    {
        NSLog(@"Failed to write to file %@", error);
    }
    NSUInteger byteCount = resizedImageData.length;
    format.diskSize += byteCount;
    [self controlDiskCapacityOfFormat:format];
}

- (void)updateAccessDateOfImage:(UIImage*)image entityId:(NSString*)entityId format:(HNKCacheFormat*)format
{
    NSString *path = [self pathForEntityId:entityId format:format];
    NSDate *now = [NSDate date];
    NSDictionary* attributes = @{NSFileModificationDate : now};
    NSError *error;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![[NSFileManager defaultManager] setAttributes:attributes ofItemAtPath:path error:&error])
    {
        if ([fileManager fileExistsAtPath:path isDirectory:nil])
        {
            NSLog(@"Set attributes failed with error %@", [error localizedDescription]);
        }
        else
        {
            [self saveImage:image entityId:entityId format:format];
        }
    }
}

#pragma mark - Notifications

- (void)didReceiveMemoryWarning:(NSNotification*)notification
{
    [_memoryCaches enumerateKeysAndObjectsUsingBlock:^(id key, NSCache *cache, BOOL *stop) {
        [cache removeAllObjects];
    }];
}

@end

@implementation HNKCacheFormat

- (id)initWithName:(NSString *)name
{
    self = [super init];
    if (self)
    {
        _name = name;
        _compressionQuality = 1;
    }
    return self;
}

- (UIImage*)resizedImageFromImage:(UIImage*)originalImage
{
    const CGSize formatSize = self.size;
    CGSize resizedSize;
    switch (self.scaleMode) {
        case HNKScaleModeAspectFill:
            resizedSize = [originalImage hnk_aspectFillSizeForSize:formatSize];
            break;
        case HNKScaleModeAspectFit:
            resizedSize = [originalImage hnk_aspectFitSizeForSize:formatSize];
            break;
        case HNKScaleModeFill:
            resizedSize = formatSize;
            break;
    }
    if (!self.allowUpscaling)
    {
        CGSize originalSize = originalImage.size;
        if (resizedSize.width > originalSize.width || resizedSize.height > originalSize.height)
        {
            return originalImage;
        }
    }
    UIImage *image = [originalImage hnk_imageByScalingToSize:resizedSize];
    return image;
}

#pragma mark Private

- (NSString*)directory
{
    NSString *rootDirectory = self.cache.rootDirectory;
    NSString *directory = [rootDirectory stringByAppendingPathComponent:self.name];
    NSError *error;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error])
    {
        NSLog(@"Failed to create directory with error %@", error);
    }
    return directory;
}

@end

@implementation UIImage (hnk_utils)

- (CGSize)hnk_aspectFillSizeForSize:(CGSize)size
{
    CGFloat targetAspect = size.width / size.height;
    CGFloat sourceAspect = self.size.width / self.size.height;
    CGSize result = CGSizeZero;
    
    if (targetAspect > sourceAspect)
    {
        result.height = size.height;
        result.width = result.height * sourceAspect;
    }
    else
    {
        result.height = size.height;
        result.width = result.height * sourceAspect;
    }
    return CGSizeMake(ceil(result.width), ceil(result.height));
}

- (CGSize)hnk_aspectFitSizeForSize:(CGSize)size
{
    CGFloat targetAspect = size.width / size.height;
    CGFloat sourceAspect = self.size.width / self.size.height;
    CGSize result = CGSizeZero;
    
    if (targetAspect > sourceAspect)
    {
        result.height = size.height;
        result.width = result.height * sourceAspect;
    }
    else
    {
        result.width = size.width;
        result.height = result.width / sourceAspect;
    }
    return CGSizeMake(ceil(result.width), ceil(result.height));
}

- (UIImage *)hnk_imageByScalingToSize:(CGSize)newSize
{
    UIGraphicsBeginImageContextWithOptions(newSize, NO, 0.0);
    [self drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
    UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return newImage;
}

@end