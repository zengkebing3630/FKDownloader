//
//  FKTask.m
//  FKDownloader
//
//  Created by Norld on 2018/11/1.
//  Copyright © 2018 Norld. All rights reserved.
//

#import "FKTask.h"
#import "FKDownloadManager.h"
#import "FKConfigure.h"
#import "FKHashHelper.h"
#import "FKResumeHelper.h"
#import "NSString+FKDownload.h"
#import "FKReachability.h"

NS_ASSUME_NONNULL_BEGIN

@interface FKTask ()

@property (nonatomic, strong) NSURLSessionDownloadTask *downloadTask;
@property (nonatomic, strong) NSString          *identifier;
@property (nonatomic, strong) NSProgress        *progress;
@property (nonatomic, strong, nullable) NSData            *resumeData;

// TODO: 只在任务运行期间进行计时
@property (nonatomic, strong, nullable) NSTimer           *timer;

@property (nonatomic, assign) NSTimeInterval    prevTime;
@property (nonatomic, assign) int64_t           prevReceivedBytes;
@property (nonatomic, strong) NSNumber          *estimatedTimeRemaining;
@property (nonatomic, strong) NSNumber          *bytesPerSecondSpeed;

@property (nonatomic, assign) BOOL              isPassChecksum;

@end

NS_ASSUME_NONNULL_END

@implementation FKTask
@synthesize resumeData = _resumeData;


#pragma mark - Init
- (instancetype)init {
    self = [super init];
    if (self) {
        
    }
    return self;
}

- (void)setupTimer {
    if (!self.timer.isValid) {
        self.timer = [NSTimer timerWithTimeInterval:[FKDownloadManager manager].configure.speedRefreshInterval
                                             target:self
                                           selector:@selector(refreshSpeed)
                                           userInfo:nil
                                            repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    }
}


#pragma mark - Coding
- (void)encodeWithCoder:(NSCoder *)aCoder {
    // url, fileName, verification, verificationType, requestHeader, status, progress
    [aCoder encodeObject:self.url               forKey:@"url"];
    [aCoder encodeObject:self.fileName          forKey:@"fileName"];
    [aCoder encodeObject:self.verification      forKey:@"verification"];
    [aCoder encodeInteger:self.verificationType forKey:@"verificationType"];
    [aCoder encodeObject:self.requestHeader     forKey:@"requestHeader"];
    [aCoder encodeInteger:self.status           forKey:@"status"];
    [aCoder encodeInt64:self.progress.totalUnitCount        forKey:@"totalUnitCount"];
    [aCoder encodeInt64:self.progress.completedUnitCount    forKey:@"completedUnitCount"];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    self = [super init];
    if (self) {
        self.url                = [aDecoder decodeObjectForKey:@"url"];
        self.fileName           = [aDecoder decodeObjectForKey:@"fileName"];
        self.verification       = [aDecoder decodeObjectForKey:@"verification"];
        self.verificationType   = [aDecoder decodeIntegerForKey:@"verificationType"];
        self.requestHeader      = [aDecoder decodeObjectForKey:@"requestHeader"];
        self.status             = [aDecoder decodeIntegerForKey:@"status"];
        self.progress.totalUnitCount        = [aDecoder decodeInt64ForKey:@"totalUnitCount"];
        self.progress.completedUnitCount    = [aDecoder decodeInt64ForKey:@"completedUnitCount"];
    }
    return self;
}


#pragma mark - Operation
- (void)restore:(NSURLSessionDownloadTask *)task {
    [self clear];
    self.downloadTask = task;
    [self addProgressObserver];
    
    switch (task.state) {
        case NSURLSessionTaskStateRunning:
            self.status = TaskStatusExecuting;
            break;
            
        case NSURLSessionTaskStateSuspended:
            // tips: 后台任务没有暂停状态
            self.status = TaskStatusSuspend;
            break;
            
        case NSURLSessionTaskStateCanceling:
            // !!!: iOS 12/12.1, 机型 8 以下.  BUG: 完全退出 app, 后台下载异常停止, 状态码为 Cancelld, 需要识别是否有恢复数据, 继续下载
            self.status = TaskStatusCancelld;
            break;
            
        case NSURLSessionTaskStateCompleted:
            if (self.isHasResumeData) {
                self.status = TaskStatusSuspend;
            } else {
                self.status = TaskStatusFinish;
            }
            break;
    }
}

- (void)settingInfo:(NSDictionary *)info {
    if ([info.allKeys containsObject:FKTaskInfoURL]) {
        self.url = info[FKTaskInfoURL];
    }
    
    if ([info.allKeys containsObject:FKTaskInfoFileName]) {
        self.fileName = info[FKTaskInfoFileName];
    }
    
    if ([info.allKeys containsObject:FKTaskInfoVerificationType]) {
        self.verificationType = [info[FKTaskInfoVerificationType] unsignedIntegerValue];
    }
    
    if ([info.allKeys containsObject:FKTaskInfoVerification]) {
        self.verification = info[FKTaskInfoVerification];
    }
    
    if ([info.allKeys containsObject:FKTaskInfoRequestHeader]) {
        self.requestHeader = info[FKTaskInfoRequestHeader];
    }
}

- (void)reday {
    FKLog(@"开始准备: %@", self)
    [self sendPrepareInfo];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:self.url]];
    [self.requestHeader enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        [request setValue:value forHTTPHeaderField:key];
    }];
    if ([self.manager.fileManager fileExistsAtPath:[self resumeFilePath]]) {
        [self removeProgressObserver];
        self.downloadTask = [self.manager.session downloadTaskWithResumeData:[self resumeData]];
        [self clearResumeData];
    } else {
        self.downloadTask = [self.manager.session downloadTaskWithRequest:request];
    }
    
    [self addProgressObserver];
    self.prevTime = 1;
    self.bytesPerSecondSpeed = [NSNumber numberWithLongLong:0];
    self.estimatedTimeRemaining = [NSNumber numberWithLongLong:0];
}

- (void)addProgressObserver {
    [self.downloadTask addObserver:self
                        forKeyPath:NSStringFromSelector(@selector(countOfBytesReceived))
                           options:NSKeyValueObservingOptionNew
                           context:nil];
    [self.downloadTask addObserver:self
                        forKeyPath:NSStringFromSelector(@selector(countOfBytesExpectedToReceive)) options:NSKeyValueObservingOptionNew
                           context:nil];
}

- (void)removeProgressObserver {
    [self.downloadTask removeObserver:self forKeyPath:NSStringFromSelector(@selector(countOfBytesReceived))];
    [self.downloadTask removeObserver:self forKeyPath:NSStringFromSelector(@selector(countOfBytesExpectedToReceive))];
}

- (void)execute {
    FKLog(@"执行: %@", self)
    if (self.manager.reachability.currentReachabilityStatus == NotReachable ||
        (!self.manager.configure.isAllowCellular && (self.manager.reachability.currentReachabilityStatus == ReachableViaWWAN))) {
        
        self.error = [NSError errorWithDomain:NSURLErrorDomain
                                         code:NSURLErrorNotConnectedToInternet
                                     userInfo:@{NSFilePathErrorKey: self.url,
                                                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Network Unavailable"]}];
        [self sendIdleInfo];
        return;
    }
    
    [self sendWillExecutingInfo];
    
    if (self.isFinish) {
        FKLog(@"文件早已下载完成: %@", self)
        self.progress.totalUnitCount = 1;
        self.progress.completedUnitCount = 1;
        [self sendFinishInfo];
    } else if (self.isHasResumeData) {
        FKLog(@"检测到恢复数据: %@", self)
        [self setupTimer];
        [self resume];
    } else {
        FKLog(@"没有恢复数据: %@", self)
        [self setupTimer];
        [self.downloadTask resume];
        [self sendExecutingInfo];
    }
}

- (void)suspend {
    [self suspendWithComplete:^{ }];
}

- (void)suspendWithComplete:(void (^)(void))complete {
    [self sendWillSuspendInfo];
    
    // !!!: https://stackoverflow.com/questions/39346231/resume-nsurlsession-on-ios10/39347461#39347461
    // tips: iOS 12/12.1 resumeData 与之前格式不一致, 之前保存的文件为 xml 格式的二进制数据, 新的格式需要 NSKeyedUnarchiver 解码后才可得到与之前一致的 NSDictionary, 但是不影响正常使用.
    __weak typeof(self) weak = self;
    [self.downloadTask cancelByProducingResumeData:^(NSData *resumeData) {
        __strong typeof(weak) strong = weak;
        strong.bytesPerSecondSpeed = [NSNumber numberWithLongLong:0];
        strong.estimatedTimeRemaining = [NSNumber numberWithLongLong:0];
        if (resumeData) {
            strong.resumeData = [FKResumeHelper correctResumeData:resumeData];
            FKLog(@"%@", [FKResumeHelper readResumeData:resumeData]);
        }
        if (complete) {
            // !!!: 此处使用 dispatch_after 是为了唤醒下载线程和防止写入恢复数据/读取回复数据冲突导致 fix 后台下载进度失败
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                complete();
            });
        }
    }];
}

- (void)resume {
    [self sendResumingInfo];
    
    if (self.manager.reachability.currentReachabilityStatus == NotReachable ||
        (!self.manager.configure.isAllowCellular && (self.manager.reachability.currentReachabilityStatus == ReachableViaWWAN))) {
        
        self.error = [NSError errorWithDomain:NSURLErrorDomain
                                         code:NSURLErrorNotConnectedToInternet
                                     userInfo:@{NSFilePathErrorKey: self.url,
                                                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Network Unavailable"]}];
        [self sendIdleInfo];
        return;
    }
    
    [self removeProgressObserver];
    self.downloadTask = [self.manager.session downloadTaskWithResumeData:self.resumeData];
    [self clearResumeData];
    [self addProgressObserver];
    [self.downloadTask resume];
    
    [self sendExecutingInfo];
}

- (void)cancel {
    [self sendWillCancelldInfo];
    
    // 已完成下载的忽略停止操作
    if (self.isFinish) {
        [self sendCancelldInfo];
        return;
    }
    
    if (self.status == TaskStatusCancelld ||
        self.status == TaskStatusNone ||
        self.status == TaskStatusIdle) {
        
        [self sendCancelldInfo];
    }
    // !!!: 带有恢复数据的系统任务暂停后, 状态为已完成, 需手动做取消通知和数据清理
    if (self.status == TaskStatusSuspend) {
        self.bytesPerSecondSpeed = [NSNumber numberWithLongLong:0];
        self.estimatedTimeRemaining = [NSNumber numberWithLongLong:0];
        [self clearResumeData];
        [self sendCancelldInfo];
    }
    
    [self.downloadTask cancel];
    self.progress.completedUnitCount = 0;
    self.bytesPerSecondSpeed = [NSNumber numberWithLongLong:0];
    self.estimatedTimeRemaining = [NSNumber numberWithLongLong:0];
    [self clearSpeedTimer];
}

- (BOOL)checksum {
    if (self.manager.configure.isFileChecksum && self.verification.length) {
        [self sendWillChecksumInfo];
        switch (self.verificationType) {
            case VerifyTypeMD5:
                self.isPassChecksum = [[FKHashHelper MD5:[self filePath]] isEqualToString:self.verification];
                [self sendChecksumInfo];
                return self.isPassChecksum;
                
            case VerifyTypeSHA1:
                self.isPassChecksum = [[FKHashHelper SHA1:[self filePath]] isEqualToString:self.verification];
                [self sendChecksumInfo];
                return self.isPassChecksum;
                
            case VerifyTypeSHA256:
                self.isPassChecksum = [[FKHashHelper SHA256:[self filePath]] isEqualToString:self.verification];
                [self sendChecksumInfo];
                return self.isPassChecksum;
                
            case VerifyTypeSHA512:
                self.isPassChecksum = [[FKHashHelper SHA512:[self filePath]] isEqualToString:self.verification];
                [self sendChecksumInfo];
                return self.isPassChecksum;
        }
    } else {
        return YES;
    }
}

- (void)clear {
    [self removeProgressObserver];
    [self clearResumeData];
    [self clearSpeedTimer];
}

- (void)updateURL:(NSString *)url {
    if (self.status != TaskStatusExecuting) {
        if (self.isHasResumeData) {
            NSData *resumeData = [NSData dataWithContentsOfFile:self.resumeFilePath options:NSDataReadingMappedIfSafe error:nil];
            self.resumeData = [FKResumeHelper updateResumeData:resumeData url:url];
        }
        self.url = url;
    }
}


#pragma mark - Send Info
- (void)sendIdleInfo {
    self.status = TaskStatusIdle;
    
    if ([self.delegate respondsToSelector:@selector(downloader:didIdleTask:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate downloader:self.manager didIdleTask:self];
        });
    }
    if (self.statusBlock) {
        __weak typeof(self) weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weak.statusBlock(weak);
        });
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FKTaskDidIdleNotification object:nil];
    });
}

- (void)sendPrepareInfo {
    self.status = TaskStatusPrepare;
    
    if ([self.delegate respondsToSelector:@selector(downloader:prepareTask:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate downloader:self.manager prepareTask:self];
        });
    }
    if (self.statusBlock) {
        __weak typeof(self) weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weak.statusBlock(weak);
        });
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:FKTaskPrepareNotification object:nil];
}

- (void)sendResumingInfo {
    self.status = TaskStatusResuming;
    
    if ([self.delegate respondsToSelector:@selector(downloader:didResumingTask:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate downloader:self.manager didResumingTask:self];
        });
    }
    if (self.statusBlock) {
        __weak typeof(self) weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weak.statusBlock(weak);
        });
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:FKTaskDidResumingNotification object:nil];
}

- (void)sendWillExecutingInfo {
    if ([self.delegate respondsToSelector:@selector(downloader:willExecuteTask:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate downloader:self.manager willExecuteTask:self];
        });
    }
    if (self.statusBlock) {
        __weak typeof(self) weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weak.statusBlock(weak);
        });
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:FKTaskWillExecuteNotification object:nil];
}

- (void)sendExecutingInfo {
    self.status = TaskStatusExecuting;
    
    if ([self.delegate respondsToSelector:@selector(downloader:didExecuteTask:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate downloader:self.manager didExecuteTask:self];
        });
    }
    if (self.statusBlock) {
        __weak typeof(self) weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weak.statusBlock(weak);
        });
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FKTaskDidExecuteNotification object:nil];
    });
}

- (void)sendWillSuspendInfo {
    if ([self.delegate respondsToSelector:@selector(downloader:willSuspendTask:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate downloader:self.manager willSuspendTask:self];
        });
    }
    if (self.statusBlock) {
        __weak typeof(self) weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weak.statusBlock(weak);
        });
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FKTaskWillSuspendNotification object:nil];
    });
}

- (void)sendSuspendInfo {
    self.status = TaskStatusSuspend;
    
    if ([self.delegate respondsToSelector:@selector(downloader:didSuspendTask:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate downloader:self.manager didSuspendTask:self];
        });
    }
    if (self.statusBlock) {
        __weak typeof(self) weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weak.statusBlock(weak);
        });
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FKTaskDidSuspendNotification object:nil];
    });
}

- (void)sendWillCancelldInfo {
    if ([self.delegate respondsToSelector:@selector(downloader:willCanceldTask:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate downloader:self.manager willCanceldTask:self];
        });
    }
    if (self.statusBlock) {
        __weak typeof(self) weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weak.statusBlock(weak);
        });
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FKTaskWillCancelldNotification object:nil];
    });
}

- (void)sendCancelldInfo {
    self.status = TaskStatusCancelld;
    
    if ([self.delegate respondsToSelector:@selector(downloader:didCancelldTask:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate downloader:self.manager didCancelldTask:self];
        });
    }
    if (self.statusBlock) {
        __weak typeof(self) weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weak.statusBlock(weak);
        });
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FKTaskDidCancelldNotification object:nil];
    });
    
    if (self.manager.configure.isAutoClearTask) {
        [self.manager remove:self.url];
    }
}

- (void)sendWillChecksumInfo {
    self.status = TaskStatusChecksumming;
    
    if ([self.delegate respondsToSelector:@selector(downloader:willChecksumTask:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate downloader:self.manager willChecksumTask:self];
        });
    }
    if (self.statusBlock) {
        __weak typeof(self) weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weak.statusBlock(weak);
        });
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FKTaskWillChecksumNotification object:nil];
    });
}

- (void)sendChecksumInfo {
    self.status = TaskStatusChecksummed;
    
    if ([self.delegate respondsToSelector:@selector(downloader:didChecksumTask:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate downloader:self.manager didChecksumTask:self];
        });
    }
    if (self.statusBlock) {
        __weak typeof(self) weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weak.statusBlock(weak);
        });
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FKTaskDidChecksumNotification object:nil];
    });
}

- (void)sendFinishInfo {
    self.status = TaskStatusFinish;
    
    if ([self.delegate respondsToSelector:@selector(downloader:didFinishTask:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate downloader:self.manager didFinishTask:self];
        });
    }
    if (self.statusBlock) {
        __weak typeof(self) weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weak.statusBlock(weak);
        });
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FKTaskDidFinishNotification object:nil];
    });
    
    if (self.manager.configure.isAutoClearTask) {
        [self.manager remove:self.url];
    }
}

- (void)sendErrorInfo:(NSError *)error {
    self.error = error;
    self.status = TaskStatusUnknowError;
    [self clearResumeData];
    
    if ([self.delegate respondsToSelector:@selector(downloader:errorTask:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate downloader:self.manager errorTask:self];
        });
    }
    if (self.statusBlock) {
        __weak typeof(self) weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weak.statusBlock(weak);
        });
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FKTaskErrorNotification object:nil];
    });
}

- (void)sendProgressInfo {
    if ([self.delegate respondsToSelector:@selector(downloader:progressingTask:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate downloader:self.manager progressingTask:self];
        });
    }
    if (self.progressBlock) {
        __weak typeof(self) weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weak.progressBlock(weak);
        });
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FKTaskProgressNotification object:nil];
    });
}

- (void)sendSpeedInfo {
    if ([self.delegate respondsToSelector:@selector(downloader:speedInfo:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate downloader:self.manager speedInfo:self];
        });
    }
    if (self.speedBlock) {
        __weak typeof(self) weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weak.speedBlock(weak);
        });
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FKTaskSpeedInfoNotification object:nil];
    });
}


#pragma mark - Description
- (NSString *)statusDescription:(TaskStatus)status {
    NSString *description = @"";
    switch (status) {
        case TaskStatusNone:
            description = @"TaskStatusNone";
            break;
            
        case TaskStatusPrepare:
            description = @"TaskStatusPrepare";
            break;
            
        case TaskStatusIdle:
            description = @"TaskStatusIdle";
            break;
            
        case TaskStatusExecuting:
            description = @"TaskStatusExecuting";
            break;
            
        case TaskStatusFinish:
            description = @"TaskStatusFinish";
            break;
            
        case TaskStatusSuspend:
            description = @"TaskStatusSuspend";
            break;
            
        case TaskStatusResuming:
            description = @"TaskStatusResuming";
            break;
            
        case TaskStatusChecksumming:
            description = @"TaskStatusChecksumming";
            break;
            
        case TaskStatusChecksummed:
            description = @"TaskStatusChecksummed";
            break;
            
        case TaskStatusCancelld:
            description = @"TaskStatusCancelld";
            break;
            
        case TaskStatusUnknowError:
            description = @"TaskStatusUnknowError";
            break;
    }
    return description;
}


#pragma mark - Basic
- (NSString *)filePath {
    if (self.fileName.length) {
        NSString *fileName = [NSString stringWithFormat:@"%@.%@", self.fileName, [NSURL URLWithString:self.url].pathExtension];
        return [self.manager.configure.savePath stringByAppendingPathComponent:fileName];
    } else {
        NSString *fileName = [NSString stringWithFormat:@"%@", [NSURL URLWithString:self.url].lastPathComponent];
        return [self.manager.configure.savePath stringByAppendingPathComponent:fileName];
    }
}

- (NSString *)resumeFilePath {
    NSString *fileName = [NSString stringWithFormat:@"%@.resume", self.identifier];
    return [self.manager.configure.resumePath stringByAppendingPathComponent:fileName];
}

- (BOOL)isHasResumeData {
    // !!!: 判断缓存文件是否还存在, 当开始下载时缓存文件位置为 Library/Caches/com.apple.nsurlsessiond/Downloads/“Bundle ID”/“NSURLSessionResumeInfoTempFileName”, 当暂停时缓存文件为 temp/“NSURLSessionResumeInfoTempFileName”
    if ([self.manager.fileManager fileExistsAtPath:[self resumeFilePath]]) {
        NSDictionary *resumeDictionary = [FKResumeHelper readResumeData:[NSData dataWithContentsOfFile:self.resumeFilePath options:NSDataReadingMappedIfSafe error:nil]];
        NSString *tempFilePath = @"";
        if ([resumeDictionary[@"NSURLSessionResumeInfoVersion"] integerValue] == 1 ||
            [resumeDictionary.allKeys containsObject:@"NSURLSessionResumeInfoLocalPath"]) {
            
            tempFilePath = resumeDictionary[@"NSURLSessionResumeInfoLocalPath"];
        } else {
            tempFilePath = [[self tempPath] stringByAppendingPathComponent:resumeDictionary[@"NSURLSessionResumeInfoTempFileName"]];
        }
        
        if ([self.manager.fileManager fileExistsAtPath:tempFilePath]) {
            return YES;
        } else {
            return NO;
        }
    } else {
        return NO;
    }
}

- (BOOL)isFinish {
    return [self.manager.fileManager fileExistsAtPath:[self filePath]];
}


#pragma mark - KVO
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    
    if ([keyPath isEqualToString:NSStringFromSelector(@selector(countOfBytesReceived))]) {
        self.progress.completedUnitCount = self.downloadTask.countOfBytesReceived;
    }
    if ([keyPath isEqualToString:NSStringFromSelector(@selector(countOfBytesExpectedToReceive))]) {
        self.progress.totalUnitCount = self.downloadTask.countOfBytesExpectedToReceive;
    }
    [self sendProgressInfo];
}


#pragma mark - Private Method
- (void)clearResumeData {
    self.resumeData = nil;
    if (self.isHasResumeData) {
        [self.manager.fileManager removeItemAtPath:[self resumeFilePath] error:nil];
    }
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p> <URL: %@, status: %@>", NSStringFromClass([self class]), self, self.url, [self statusDescription:self.status]];
}

- (void)refreshSpeed {
    if (self.status != TaskStatusExecuting || self.downloadTask.state != NSURLSessionTaskStateRunning) {
        return;
    }
    
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    int64_t receivedCount = self.downloadTask.countOfBytesReceived - self.prevReceivedBytes;
    self.bytesPerSecondSpeed = [NSNumber numberWithDouble:(receivedCount / (now - self.prevTime))];
    self.prevTime = now;
    self.prevReceivedBytes = self.downloadTask.countOfBytesReceived;
    
    double remaining = (self.progress.totalUnitCount - self.progress.completedUnitCount) / (receivedCount?:1);
    self.estimatedTimeRemaining = [NSNumber numberWithDouble:remaining];
    
    [self sendSpeedInfo];
}

- (void)clearSpeedTimer {
    if (self.timer || !self.timer.isValid) {
        [self.timer invalidate];
        self.timer = nil;
    }
}

- (NSString *)tempPath {
    return NSTemporaryDirectory();
}


#pragma mark - Getter/Setter
- (void)setUrl:(NSString *)url {
    _url = url;
    
    NSURL *u = [NSURL URLWithString:url];
    self.identifier = [[NSString stringWithFormat:@"%@://%@%@", u.scheme, u.host, u.path] SHA256];
}

- (void)setDelegate:(id<FKTaskDelegate>)delegate {
    _delegate = delegate;
    
    switch (self.status) {
        case TaskStatusPrepare: {
            [self sendPrepareInfo];
        } break;
            
        case TaskStatusIdle: {
            [self sendIdleInfo];
        } break;
            
        case TaskStatusExecuting: {
            [self sendExecutingInfo];
        } break;
            
        case TaskStatusFinish: {
            [self sendFinishInfo];
        } break;
            
        case TaskStatusSuspend: {
            [self sendSuspendInfo];
        } break;
            
        case TaskStatusResuming: {
            [self sendResumingInfo];
        } break;
            
        case TaskStatusChecksumming: {
            [self sendWillChecksumInfo];
        } break;
            
        case TaskStatusChecksummed: {
            [self sendChecksumInfo];
        } break;
            
        case TaskStatusCancelld: {
            [self sendCancelldInfo];
        } break;
            
        case TaskStatusUnknowError: {
            [self sendErrorInfo:self.error];
        } break;
            
        default:
            break;
    }
    
    [self sendProgressInfo];
}

- (NSData *)resumeData {
    NSError *error;
    NSData *resumeData = [NSData dataWithContentsOfFile:[self resumeFilePath] options:NSDataReadingMappedIfSafe error:&error];
    if (error) {
        FKLog(@"读取恢复数据失败: %@", error)
        return nil;
    } else {
        return resumeData;
    }
}

- (void)setResumeData:(NSData *)resumeData {
    _resumeData = resumeData;
    [resumeData writeToFile:[self resumeFilePath] atomically:YES];
}

- (NSString *)fileName {
    if (!_fileName) {
        _fileName = @"";
    }
    return _fileName;
}

- (NSString *)verification {
    if (!_verification) {
        _verification = @"";
    }
    return _verification;
}

- (NSDictionary *)requestHeader {
    if (!_requestHeader) {
        _requestHeader = [NSDictionary dictionary];
    }
    return _requestHeader;
}

- (NSProgress *)progress {
    if (!_progress) {
        self.manager.progress.totalUnitCount += 100;
        [self.manager.progress becomeCurrentWithPendingUnitCount:100];
        _progress = [NSProgress progressWithTotalUnitCount:0];
        [self.manager.progress resignCurrent];
    }
    return _progress;
}

- (void)setStatus:(TaskStatus)status {
    [self willChangeValueForKey:@"status"];
    _status = status;
    [self didChangeValueForKey:@"status"];
}

- (NSString *)estimatedTimeRemainingDescription {
    NSString *remaining = @"";
    NSInteger seconds = self.estimatedTimeRemaining.longLongValue % 60;
    remaining = [[NSString stringWithFormat:@"%lds", (long)seconds] stringByAppendingString:remaining];
    
    NSInteger minutes = self.estimatedTimeRemaining.longLongValue / 60 % 60;
    if (minutes) {
        remaining = [[NSString stringWithFormat:@"%ldm:", (long)minutes] stringByAppendingString:remaining];
    }
    
    NSInteger hours = self.estimatedTimeRemaining.doubleValue / (60 * 60);
    if (hours) {
        remaining = [[NSString stringWithFormat:@"%ldh:", (long)hours] stringByAppendingString:remaining];
    }
    
    return [NSString stringWithFormat:@"%@", remaining];
}

- (NSString *)bytesPerSecondSpeedDescription {
    return [NSString stringWithFormat:@"%@/s", [NSByteCountFormatter stringFromByteCount:(self.bytesPerSecondSpeed ?: 0).longLongValue countStyle:NSByteCountFormatterCountStyleBinary]];
}

@end
