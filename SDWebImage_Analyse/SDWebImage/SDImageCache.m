/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDImageCache.h"
#import "SDWebImageDecoder.h"
#import "UIImage+MultiFormat.h"
#import <CommonCrypto/CommonDigest.h>

// See https://github.com/rs/SDWebImage/pull/1141 for discussion

@interface AutoPurgeCache : NSCache
@end

@implementation AutoPurgeCache

- (id)init
{
    // 初始化的内存缓存类AutoPurgeCache，使用NSCache派生得到
    self = [super init];
    if (self) {
        // 整个类中只有一个逻辑，就是添加观察者，在内存警告时，调用NSCache的@selector(removeAllObjects)，清空内存缓存。
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(removeAllObjects) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];

}

@end

static const NSInteger kDefaultCacheMaxCacheAge = 60 * 60 * 24 * 7; // 1 week
// PNG signature bytes and data (below)
static unsigned char kPNGSignatureBytes[8] = {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
static NSData *kPNGSignatureData = nil;

BOOL ImageDataHasPNGPreffix(NSData *data);

BOOL ImageDataHasPNGPreffix(NSData *data) {
    NSUInteger pngSignatureLength = [kPNGSignatureData length];
    if ([data length] >= pngSignatureLength) {
        if ([[data subdataWithRange:NSMakeRange(0, pngSignatureLength)] isEqualToData:kPNGSignatureData]) {
            return YES;
        }
    }

    return NO;
}

FOUNDATION_STATIC_INLINE NSUInteger SDCacheCostForImage(UIImage *image) {
    return image.size.height * image.size.width * image.scale * image.scale;
}

@interface SDImageCache ()

@property (strong, nonatomic) NSCache *memCache;
@property (strong, nonatomic) NSString *diskCachePath;
@property (strong, nonatomic) NSMutableArray *customPaths;
@property (SDDispatchQueueSetterSementics, nonatomic) dispatch_queue_t ioQueue;

@end

// 这个类就管理缓存相关逻辑，本地硬盘缓存，内存缓存，内存告警时候的处理，图片过期处理，后台运行处理
//图片内存缓存是用NSCache来管理
@implementation SDImageCache {
    NSFileManager *_fileManager;
}

// SDImageCache类管理着内存缓存和可选的磁盘缓存
+ (SDImageCache *)sharedImageCache {
    static dispatch_once_t once;
    static id instance;
    //使用dispatch_once防止多线程环境下生成多个实例
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

- (id)init {
    //单例sharedImageCache使用default的命名空间
    return [self initWithNamespace:@"default"];
}

// 而我们自己也可以通过使用initWithNamespace:或initWithNamespace:diskCacheDirectory:来创建另外的命名空间。
- (id)initWithNamespace:(NSString *)ns {
    NSString *path = [self makeDiskCachePath:ns];
    return [self initWithNamespace:ns diskCacheDirectory:path];
}

- (id)initWithNamespace:(NSString *)ns diskCacheDirectory:(NSString *)directory {
    if ((self = [super init])) {
        NSString *fullNamespace = [@"com.hackemist.SDWebImageCache." stringByAppendingString:ns];

        //  初始化PNG标记数据
        kPNGSignatureData = [NSData dataWithBytes:kPNGSignatureBytes length:8];

        // 创建ioQueue串行队列负责对硬盘的读写
        _ioQueue = dispatch_queue_create("com.hackemist.SDWebImageCache", DISPATCH_QUEUE_SERIAL);  //串行队列

        // 初始化默认的最大缓存时间
        _maxCacheAge = kDefaultCacheMaxCacheAge;

        // 内存缓存是用NSCache来管理
        _memCache = [[AutoPurgeCache alloc] init];
        
        _memCache.name = fullNamespace;

        // 初始化磁盘缓存
        if (directory != nil) {
            _diskCachePath = [directory stringByAppendingPathComponent:fullNamespace];
        } else {
            NSString *path = [self makeDiskCachePath:ns];
            _diskCachePath = path;
        }

        // 设置默认解压缩图片
        _shouldDecompressImages = YES;

        // 设置默认开启内存缓存
        _shouldCacheImagesInMemory = YES;

        // 设置默认不使用iCloud
        _shouldDisableiCloud = YES;

        dispatch_sync(_ioQueue, ^{
            _fileManager = [NSFileManager new];
        });

#if TARGET_OS_IPHONE
        // Subscribe to app events
        //收到内存警告时，清除NSCache：[self.memCache removeAllObjects];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(clearMemory)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];

        //程序关闭时，会对硬盘文件做一些处理
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(cleanDisk)
                                                     name:UIApplicationWillTerminateNotification
                                                   object:nil];

        //程序进入后台时，也会进行硬盘文件处理
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(backgroundCleanDisk)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
#endif
    }

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    SDDispatchQueueRelease(_ioQueue);
}

- (void)addReadOnlyCachePath:(NSString *)path {
    if (!self.customPaths) {
        self.customPaths = [NSMutableArray new];
    }

    if (![self.customPaths containsObject:path]) {
        [self.customPaths addObject:path];
    }
}

//返回缓存完整路径，其中文件名是根据key值生成的MD5值
- (NSString *)cachePathForKey:(NSString *)key inPath:(NSString *)path {
    NSString *filename = [self cachedFileNameForKey:key];
    return [path stringByAppendingPathComponent:filename];
}

- (NSString *)defaultCachePathForKey:(NSString *)key {
    return [self cachePathForKey:key inPath:self.diskCachePath];
}

#pragma mark SDImageCache (private)

#pragma mark -- MD5计算
- (NSString *)cachedFileNameForKey:(NSString *)key {
     // 根据key生成对应的MD5值作为文件名
    const char *str = [key UTF8String];
    if (str == NULL) {
        str = "";
    }
    unsigned char r[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, (CC_LONG)strlen(str), r);
    NSString *filename = [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%@",
                          r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10],
                          r[11], r[12], r[13], r[14], r[15], [[key pathExtension] isEqualToString:@""] ? @"" : [NSString stringWithFormat:@".%@", [key pathExtension]]];

    return filename;
}

#pragma mark ImageCache

// Init the disk cache
-(NSString *)makeDiskCachePath:(NSString*)fullNamespace{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [paths[0] stringByAppendingPathComponent:fullNamespace];
}

/*
 根据图片的不同种类，生成对应的UIImage
 根据key值，调整image的scale值
 如果设置图片需要解压缩，则还需对UIImage进行解码
 */

// 当下载完图片后，会先将图片保存到NSCache中，并把图片像素大小作为该对象的cost值，
- (void)storeImage:(UIImage *)image recalculateFromImage:(BOOL)recalculate imageData:(NSData *)imageData forKey:(NSString *)key toDisk:(BOOL)toDisk {
    if (!image || !key) {
        return;
    }
    // if memory cache is enabled
    if (self.shouldCacheImagesInMemory) {
        NSUInteger cost = SDCacheCostForImage(image);
        // 保存到NSCache，cost为像素值
        [self.memCache setObject:image forKey:key cost:cost];
    }

    if (toDisk) {
        // 图片写入到硬盘是放在一个serial queue里，一个线程顺序的写入到本地
        dispatch_async(self.ioQueue, ^{
            NSData *data = imageData;

            if (image && (recalculate || !data)) {
#if TARGET_OS_IPHONE
                // 我们需要判断图片是PNG还是JPEG格式。PNG图片很容易检测，因为它们拥有一个独特的签名<http://www.w3.org/TR/PNG-Structure.html>。PNG文件的前八字节经常包含如下(十进制)的数值：137 80 78 71 13 10 26 10
                // 如果imageData为nil（也就是说，如果试图直接保存一个UIImage或者图片是由下载转换得来）并且图片有alpha通道，我们将认为它是PNG文件以避免丢失透明度信息。
                
                int alphaInfo = CGImageGetAlphaInfo(image.CGImage);
                BOOL hasAlpha = !(alphaInfo == kCGImageAlphaNone ||
                                  alphaInfo == kCGImageAlphaNoneSkipFirst ||
                                  alphaInfo == kCGImageAlphaNoneSkipLast);
                BOOL imageIsPng = hasAlpha;

                // 查看imagedata的前缀是否是PNG的前缀格式
                if ([imageData length] >= [kPNGSignatureData length]) {
                    imageIsPng = ImageDataHasPNGPreffix(imageData);
                }

                //同时如果需要保存到硬盘，会先判断图片的格式，PNG或者JPEG，并保存对应的NSData到缓存路径中，文件名为URL的MD5值：
                if (imageIsPng) { //如果是PNG
                    data = UIImagePNGRepresentation(image);
                }
                else { //如果是JPEG
                    data = UIImageJPEGRepresentation(image, (CGFloat)1.0);
                }
#else
                data = [NSBitmapImageRep representationOfImageRepsInArray:image.representations usingType: NSJPEGFileType properties:nil];
#endif
            }

            if (data) {
                if (![_fileManager fileExistsAtPath:_diskCachePath]) {
                    [_fileManager createDirectoryAtPath:_diskCachePath withIntermediateDirectories:YES attributes:nil error:NULL];
                }

                // 获得对应图像key的完整缓存路径
                // 图片硬盘存储是存储在library cache底下的子目录里，注意这个目录apple itunes备份是不保存的，放在这里最合理，图片太多
                NSString *cachePathForKey = [self defaultCachePathForKey:key];
                // transform to NSUrl
                NSURL *fileURL = [NSURL fileURLWithPath:cachePathForKey];

                //保存data到指定的路径中
                [_fileManager createFileAtPath:cachePathForKey contents:data attributes:nil];

                // 关闭iCloud备份
                if (self.shouldDisableiCloud) {
                    [fileURL setResourceValue:[NSNumber numberWithBool:YES] forKey:NSURLIsExcludedFromBackupKey error:nil];
                }
            }
        });
    }
}

- (void)storeImage:(UIImage *)image forKey:(NSString *)key {
    [self storeImage:image recalculateFromImage:YES imageData:nil forKey:key toDisk:YES];
}

- (void)storeImage:(UIImage *)image forKey:(NSString *)key toDisk:(BOOL)toDisk {
    [self storeImage:image recalculateFromImage:YES imageData:nil forKey:key toDisk:toDisk];
}

// 检查本地硬盘是否有缓存的图片，也是在这个queue里做的

- (BOOL)diskImageExistsWithKey:(NSString *)key {
    BOOL exists = NO;
    
    // this is an exception to access the filemanager on another queue than ioQueue, but we are using the shared instance
    // from apple docs on NSFileManager: The methods of the shared NSFileManager object can be called from multiple threads safely.
    exists = [[NSFileManager defaultManager] fileExistsAtPath:[self defaultCachePathForKey:key]];

    // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
    // checking the key with and without the extension
    if (!exists) {
        exists = [[NSFileManager defaultManager] fileExistsAtPath:[[self defaultCachePathForKey:key] stringByDeletingPathExtension]];
    }
    
    return exists;
}

- (void)diskImageExistsWithKey:(NSString *)key completion:(SDWebImageCheckCacheCompletionBlock)completionBlock {
    dispatch_async(_ioQueue, ^{
        BOOL exists = [_fileManager fileExistsAtPath:[self defaultCachePathForKey:key]];

        // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
        // checking the key with and without the extension
        if (!exists) {
            exists = [_fileManager fileExistsAtPath:[[self defaultCachePathForKey:key] stringByDeletingPathExtension]];
        }

        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(exists);
            });
        }
    });
}

- (UIImage *)imageFromMemoryCacheForKey:(NSString *)key {
    return [self.memCache objectForKey:key];
}

- (UIImage *)imageFromDiskCacheForKey:(NSString *)key {

    // First check the in-memory cache...
    UIImage *image = [self imageFromMemoryCacheForKey:key];
    if (image) {
        return image;
    }

    // Second check the disk cache...
    UIImage *diskImage = [self diskImageForKey:key];
    if (diskImage && self.shouldCacheImagesInMemory) {
        NSUInteger cost = SDCacheCostForImage(diskImage);
        [self.memCache setObject:diskImage forKey:key cost:cost];
    }

    return diskImage;
}

- (NSData *)diskImageDataBySearchingAllPathsForKey:(NSString *)key {
    NSString *defaultPath = [self defaultCachePathForKey:key];
    NSData *data = [NSData dataWithContentsOfFile:defaultPath];
    if (data) {
        return data;
    }

    // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
    // checking the key with and without the extension
    data = [NSData dataWithContentsOfFile:[defaultPath stringByDeletingPathExtension]];
    if (data) {
        return data;
    }

    NSArray *customPaths = [self.customPaths copy];
    for (NSString *path in customPaths) {
        NSString *filePath = [self cachePathForKey:key inPath:path];
        NSData *imageData = [NSData dataWithContentsOfFile:filePath];
        if (imageData) {
            return imageData;
        }

        // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
        // checking the key with and without the extension
        imageData = [NSData dataWithContentsOfFile:[filePath stringByDeletingPathExtension]];
        if (imageData) {
            return imageData;
        }
    }

    return nil;
}

// 在硬盘查询的时候，会在后台将NSData转成UIImage，并完成相关的解码工作
- (UIImage *)diskImageForKey:(NSString *)key {
    NSData *data = [self diskImageDataBySearchingAllPathsForKey:key];
    if (data) {
        UIImage *image = [UIImage sd_imageWithData:data];
        image = [self scaledImageForKey:key image:image];
        if (self.shouldDecompressImages) {
            image = [UIImage decodedImageWithImage:image];
        }
        return image;
    }
    else {
        return nil;
    }
}

- (UIImage *)scaledImageForKey:(NSString *)key image:(UIImage *)image {
    return SDScaledImageForKey(key, image);
}

// 根据 key 在缓存中查找以前是否下载过相同的图片
// 异步的查询图片缓存. 因为图片的缓存可能在两个地方, 而该方法首先会在内存中查找是否有图片的缓存.
- (NSOperation *)queryDiskCacheForKey:(NSString *)key done:(SDWebImageQueryCompletedBlock)doneBlock {
    if (!doneBlock) {
        return nil;
    }

    if (!key) {
        doneBlock(nil, SDImageCacheTypeNone);
        return nil;
    }

    //  首先查询内存缓存...
    //每次向SDWebImageCache索取图片的时候，会先根据图片URL对应的key值先检查内存中是否有对应的图片，如果有则直接返回
    UIImage *image = [self imageFromMemoryCacheForKey:key]; // 首先查找内存缓存
    if (image) {
        doneBlock(image, SDImageCacheTypeMemory);
        return nil;
    }

    //如果没有,则在磁盘中查找
    NSOperation *operation = [NSOperation new];
    dispatch_async(self.ioQueue, ^{
        if (operation.isCancelled) {
            return;
        }

        //如果没有,则在磁盘中查找，其中文件名是是根据URL生成的MD5值，找到之后先将图片缓存在内存中，然后在把图片返回
        @autoreleasepool {//创建自动释放池，内存及时释放
            
            UIImage *diskImage = [self diskImageForKey:key];
            if (diskImage && self.shouldCacheImagesInMemory) {
                // 将图片保存到NSCache中，并把图片像素大小作为该对象的cost值
                NSUInteger cost = SDCacheCostForImage(diskImage);
                // 如果在磁盘中查找到对应的图片, 我们会将它复制到内存中, 以便下次的使用.
                [self.memCache setObject:diskImage forKey:key cost:cost];
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                doneBlock(diskImage, SDImageCacheTypeDisk);
            });
        }
    });

    return operation;
}

- (void)removeImageForKey:(NSString *)key {
    [self removeImageForKey:key withCompletion:nil];
}

- (void)removeImageForKey:(NSString *)key withCompletion:(SDWebImageNoParamsBlock)completion {
    [self removeImageForKey:key fromDisk:YES withCompletion:completion];
}

- (void)removeImageForKey:(NSString *)key fromDisk:(BOOL)fromDisk {
    [self removeImageForKey:key fromDisk:fromDisk withCompletion:nil];
}

// 删除本地硬盘缓存图片文件：
- (void)removeImageForKey:(NSString *)key fromDisk:(BOOL)fromDisk withCompletion:(SDWebImageNoParamsBlock)completion {
    
    if (key == nil) {
        return;
    }

    if (self.shouldCacheImagesInMemory) {
        [self.memCache removeObjectForKey:key];
    }

    if (fromDisk) {
        // 总之，涉及到IO操作的，都是单独的线程来做，这样总体来说用户体验是最佳的。
        dispatch_async(self.ioQueue, ^{
            [_fileManager removeItemAtPath:[self defaultCachePathForKey:key] error:nil];
            
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion();
                });
            }
        });
    } else if (completion){
        completion();
    }
    
}

- (void)setMaxMemoryCost:(NSUInteger)maxMemoryCost {
    self.memCache.totalCostLimit = maxMemoryCost;
}

- (NSUInteger)maxMemoryCost {
    return self.memCache.totalCostLimit;
}

- (NSUInteger)maxMemoryCountLimit {
    return self.memCache.countLimit;
}

- (void)setMaxMemoryCountLimit:(NSUInteger)maxCountLimit {
    self.memCache.countLimit = maxCountLimit;
}

- (void)clearMemory {
    [self.memCache removeAllObjects];
}

- (void)clearDisk {
    [self clearDiskOnCompletion:nil];
}

- (void)clearDiskOnCompletion:(SDWebImageNoParamsBlock)completion
{
    dispatch_async(self.ioQueue, ^{
        [_fileManager removeItemAtPath:self.diskCachePath error:nil];
        [_fileManager createDirectoryAtPath:self.diskCachePath
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:NULL];

        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion();
            });
        }
    });
}

- (void)cleanDisk {
    [self cleanDiskWithCompletionBlock:nil];
}

// 清除文件缓存
/*
 具体清理逻辑：
 
 1.先清除已超过最大缓存时间的缓存文件（最大缓存时间默认为一星期）
 2.在第一轮清除的过程中保存文件属性，特别是缓存文件大小
 3.在第一轮清除后，如果设置了最大缓存并且保留下来的磁盘缓存文件仍然超过了配置的最大缓存，那么进行第二轮以大小为基础的清除。
 4.首先删除最老的文件，直到达到期望的总的缓存大小，即最大缓存的一半。
 
 */
- (void)cleanDiskWithCompletionBlock:(SDWebImageNoParamsBlock)completionBlock {
    dispatch_async(self.ioQueue, ^{
        NSURL *diskCacheURL = [NSURL fileURLWithPath:self.diskCachePath isDirectory:YES];
        NSArray *resourceKeys = @[NSURLIsDirectoryKey, NSURLContentModificationDateKey, NSURLTotalFileAllocatedSizeKey];

        // 使用目录枚举器获取缓存文件的三个重要属性：(1)URL是否为目录；(2)内容最后更新日期；(3)文件总的分配大小。
        // 这个枚举保存我们缓存文件的属性
        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtURL:diskCacheURL
                                                   includingPropertiesForKeys:resourceKeys
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 errorHandler:NULL];

        // 计算过期日期，默认为一星期前的缓存文件认为是过期的。
        NSDate *expirationDate = [NSDate dateWithTimeIntervalSinceNow:-self.maxCacheAge];
        NSMutableDictionary *cacheFiles = [NSMutableDictionary dictionary];
        NSUInteger currentCacheSize = 0;

        // 枚举缓存目录的所有文件，此循环有两个目的：
        //
        //  1. 清除超过过期日期的文件。
        //  2. 为以大小为排序的第二轮清除保存文件属性。
        NSMutableArray *urlsToDelete = [[NSMutableArray alloc] init];
        // 1. 枚举遍历所有文件的缓存目录
        for (NSURL *fileURL in fileEnumerator) {
            NSDictionary *resourceValues = [fileURL resourceValuesForKeys:resourceKeys error:NULL];

            // 跳过目录.
            if ([resourceValues[NSURLIsDirectoryKey] boolValue]) {
                continue;
            }

            // 2.记录超过过期日期的文件;
            NSDate *modificationDate = resourceValues[NSURLContentModificationDateKey];
            if ([[modificationDate laterDate:expirationDate] isEqualToDate:expirationDate]) {
                [urlsToDelete addObject:fileURL];
                continue;
            }

            // 3.保存保留下来的文件的引用并计算文件总的大小。
            NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
            currentCacheSize += [totalAllocatedSize unsignedIntegerValue];
            [cacheFiles setObject:resourceValues forKey:fileURL];
        }
        
        // 清除记录的过期缓存文件
        for (NSURL *fileURL in urlsToDelete) {
            [_fileManager removeItemAtURL:fileURL error:nil];
        }

   
        // 如果我们保留下来的磁盘缓存文件仍然超过了配置的最大大小，那么进行第二轮以大小为基础的清除。我们首先删除最老的文件。前提是我们设置了最大缓存

        //如果剩余磁盘缓存超过缓存最大值，则删除最旧的文件
        if (self.maxCacheSize > 0 && currentCacheSize > self.maxCacheSize) {
            
            // 删除最旧的文件，直到当前缓存文件的大小为最大缓存大小的一半
            // 此轮清除的目标是最大缓存的一半。
            const NSUInteger desiredCacheSize = self.maxCacheSize / 2;

            // 用它们最后更新时间排序保留下来的缓存文件（最老的最先被清除）。
            NSArray *sortedFiles = [cacheFiles keysSortedByValueWithOptions:NSSortConcurrent
                                                            usingComparator:^NSComparisonResult(id obj1, id obj2) {
                                                                return [obj1[NSURLContentModificationDateKey] compare:obj2[NSURLContentModificationDateKey]];
                                                            }];

            // 删除文件直到低于我们所期望的缓存大小
            for (NSURL *fileURL in sortedFiles) {
                if ([_fileManager removeItemAtURL:fileURL error:nil]) {
                    NSDictionary *resourceValues = cacheFiles[fileURL];
                    NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
                    currentCacheSize -= [totalAllocatedSize unsignedIntegerValue];

                    if (currentCacheSize < desiredCacheSize) {
                        break;
                    }
                }
            }
        }
        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock();
            });
        }
    });
}

- (void)backgroundCleanDisk {
    Class UIApplicationClass = NSClassFromString(@"UIApplication");
    if(!UIApplicationClass || ![UIApplicationClass respondsToSelector:@selector(sharedApplication)]) {
        return;
    }
    UIApplication *application = [UIApplication performSelector:@selector(sharedApplication)];
    __block UIBackgroundTaskIdentifier bgTask = [application beginBackgroundTaskWithExpirationHandler:^{
        // 清理任何未完成的任务作业，标记完全停止或结束任务。
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];

    // 开始长时间后台运行的任务并且立即return。
    [self cleanDiskWithCompletionBlock:^{
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];
}

- (NSUInteger)getSize {
    __block NSUInteger size = 0;
    dispatch_sync(self.ioQueue, ^{
        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtPath:self.diskCachePath];
        for (NSString *fileName in fileEnumerator) {
            NSString *filePath = [self.diskCachePath stringByAppendingPathComponent:fileName];
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
            size += [attrs fileSize];
        }
    });
    return size;
}

- (NSUInteger)getDiskCount {
    __block NSUInteger count = 0;
    dispatch_sync(self.ioQueue, ^{
        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtPath:self.diskCachePath];
        count = [[fileEnumerator allObjects] count];
    });
    return count;
}

- (void)calculateSizeWithCompletionBlock:(SDWebImageCalculateSizeBlock)completionBlock {
    NSURL *diskCacheURL = [NSURL fileURLWithPath:self.diskCachePath isDirectory:YES];

    dispatch_async(self.ioQueue, ^{
        NSUInteger fileCount = 0;
        NSUInteger totalSize = 0;

        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtURL:diskCacheURL
                                                   includingPropertiesForKeys:@[NSFileSize]
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 errorHandler:NULL];

        for (NSURL *fileURL in fileEnumerator) {
            NSNumber *fileSize;
            [fileURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:NULL];
            totalSize += [fileSize unsignedIntegerValue];
            fileCount += 1;
        }

        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(fileCount, totalSize);
            });
        }
    });
}

@end
