//
//  KFRecorder.m
//  FFmpegEncoder
//
//  Created by Christopher Ballinger on 1/16/14.
//  Copyright (c) 2014 Christopher Ballinger. All rights reserved.
//

#import "KFRecorder.h"
#import "KFAACEncoder.h"
#import "KFH264Encoder.h"
#import "KFH264Encoder.h"
#import "KFHLSWriter.h"
#import "KFFrame.h"
#import "KFVideoFrame.h"
#import "Endian.h"
#import "HudlDirectoryWatcher.h"
#import "AssetGroup.h"
#import "HlsManifestParser.h"
#import "Utilities.h"
#import <AVFoundation/AVFoundation.h>

NSString *const NotifNewAssetGroupCreated = @"NotifNewAssetGroupCreated";
NSString *const SegmentManifestName = @"bunch";

static int32_t fragmentOrder;

@interface KFRecorder()


@property (nonatomic, strong) AVCaptureAudioDataOutput *audioOutput;
@property (nonatomic, strong) AVCaptureDeviceInput *audioInput;
@property (nonatomic, strong) AVCaptureDeviceInput *videoInput;
@property (nonatomic, strong) dispatch_queue_t audioQueue;
@property (nonatomic, strong) AVCaptureConnection *audioConnection;
@property (nonatomic, strong) AVCaptureConnection *videoConnection;

@property (nonatomic, strong) HudlDirectoryWatcher *directoryWatcher;
@property (nonatomic, strong) NSMutableSet *processedFragments;
@property (nonatomic, strong) dispatch_queue_t scanningQueue;
@property (nonatomic, strong) dispatch_source_t fileMonitorSource;

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *folderName;
@property (nonatomic, copy) NSString *hlsDirectoryPath;
@property (nonatomic) NSUInteger segmentIndex;
@property (nonatomic) BOOL foundManifest;
@property (nonatomic) CMTime originalSample;
@property (nonatomic) CMTime latestSample;
@property (nonatomic) double currentSegmentDuration;
@property (nonatomic) NSDate *lastFragmentDate;

@end

@implementation KFRecorder

+ (instancetype)recorderWithName:(NSString *)name
{
    KFRecorder *recorder = [KFRecorder new];
    recorder.name = name;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[[Utilities applicationSupportDirectory] stringByAppendingPathComponent:name] error:nil];
    recorder.segmentIndex = files.count;
    return recorder;
}

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;
    
    self.audioSampleRate = 44100;
    self.videoHeight = 1280;
    self.videoWidth = 720;
    self.audioBitrate = 128 * 1024; // 128 Kbps
    self.videoBitrate = 3 * 1024 * 1024; // 3 Mbps
    
    [self setupSession];
    self.processedFragments = [NSMutableSet new];
    self.scanningQueue = dispatch_queue_create("fsScanner", DISPATCH_QUEUE_SERIAL);
    self.videoQueue = dispatch_queue_create("Video Capture Queue", DISPATCH_QUEUE_SERIAL);
    self.isVideoCaptureSetup = NO;
    return self;
}

- (AVCaptureDevice *)audioDevice
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];
    if ([devices count] > 0)
    {
        return [devices objectAtIndex:0];
    }
    
    return nil;
}

- (void)directoryDidChange:(HudlDirectoryWatcher *)folderWatcher
{
    //NSLog(@"directoryDidChange");
    if (self.foundManifest)
    {
        return;
    }
    dispatch_async(self.scanningQueue, ^{
        NSError *error = nil;
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folderWatcher.directory error:&error];
        //NSLog(@"Directory changed, fileCount: %lu", (unsigned long)files.count);
        if (error)
        {
            //DDLogError(@"Error listing directory contents");
        }
        NSString *manifestPath = self.hlsWriter.manifestPath;
        if (!self.foundManifest)
        {
            NSFileHandle *manifest = [NSFileHandle fileHandleForReadingAtPath:manifestPath];
            if (manifest == nil) return;
            
            [self monitorFile:manifestPath];
            //NSLog(@"Monitoring manifest file");
            
            self.foundManifest = YES;
        }
    });
}

- (void)monitorFile:(NSString *)path
{
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    int fildes = open([path UTF8String], O_EVTONLY);
    if (self.fileMonitorSource)
    {
        dispatch_source_cancel(self.fileMonitorSource);
    }
    self.fileMonitorSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fildes,
                                                    DISPATCH_VNODE_DELETE | DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND |
                                                    DISPATCH_VNODE_ATTRIB | DISPATCH_VNODE_LINK | DISPATCH_VNODE_RENAME |
                                                    DISPATCH_VNODE_REVOKE, queue);
    dispatch_source_set_event_handler(self.fileMonitorSource, ^{
        unsigned long flags = dispatch_source_get_data(self.fileMonitorSource);
        if(flags & DISPATCH_VNODE_DELETE)
        {
            close(fildes);
            self.fileMonitorSource = nil;
            [self monitorFile:path];
        }
        [self bgPostNewFragmentsInManifest:path]; // update fragments after file modification
    });
    dispatch_source_set_cancel_handler(self.fileMonitorSource, ^(void) {
        close(fildes);
        self.fileMonitorSource = nil;
    });
    dispatch_resume(self.fileMonitorSource);
    [self bgPostNewFragmentsInManifest:path]; // update fragments when initial monitoring begins.
}

- (void)postNewFragmentsInManifest:(NSString *)manifestPath
{
    [self postNewFragmentsInManifest:manifestPath synchronously:YES];
}

- (void)bgPostNewFragmentsInManifest:(NSString *)manifestPath
{
    [self postNewFragmentsInManifest:manifestPath synchronously:NO];
}

- (void)postNewFragmentsInManifest:(NSString *)manifestPath synchronously:(BOOL)synchronously
{
    void (^postFragments)(void) = ^{
        NSArray *groups = [HlsManifestParser parseAssetGroupsForManifest:manifestPath];
        
        for (AssetGroup *group in groups)
        {
            //NSString *relativePath = [self.folderName stringByAppendingPathComponent:group.fileName];
            NSString *absolutePath =  [self.hlsDirectoryPath stringByAppendingPathComponent:group.fileName];
            if ([self.processedFragments containsObject:absolutePath])
            {
                continue;
            }
            [self.processedFragments addObject:absolutePath];
            
            NSDictionary* fragment = @{
                                       @"order": @((NSInteger) fragmentOrder++),
                                       @"path": absolutePath,
                                       @"manifestPath": manifestPath,
                                       @"filename": group.fileName,
                                       @"height": @((NSInteger) self.videoHeight),
                                       @"width": @((NSInteger) self.videoWidth),
                                       @"audioBitrate": @((NSInteger) self.audioBitrate),
                                       @"videoBitrate": @((NSInteger) self.videoBitrate)
                                       };
            [[NSNotificationCenter defaultCenter] postNotificationName:NotifNewAssetGroupCreated object:fragment];
            self.currentSegmentDuration += group.duration;
            self.lastFragmentDate = [NSDate date];
        }
    };
    
    if (synchronously)
    {
        dispatch_sync(self.scanningQueue, postFragments);
    }
    else
    {
        dispatch_async(self.scanningQueue, postFragments);
    }
}

- (void)setupHLSWriterWithName:(NSString *)name
{
    self.foundManifest = NO;
    NSString *basePath = [Utilities applicationSupportDirectory];
    self.folderName = name;
    NSString *hlsDirectoryPath = [basePath stringByAppendingPathComponent:self.folderName];
    self.hlsDirectoryPath = hlsDirectoryPath;
    [[NSFileManager defaultManager] createDirectoryAtPath:hlsDirectoryPath withIntermediateDirectories:YES attributes:nil error:nil];
    
    [self setupEncoders];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.directoryWatcher = [HudlDirectoryWatcher watchFolderWithPath:hlsDirectoryPath delegate:self];
    });
    self.hlsWriter = [[KFHLSWriter alloc] initWithDirectoryPath:hlsDirectoryPath segmentCount:self.segmentIndex];
    [self.hlsWriter addVideoStreamWithWidth:self.videoWidth height:self.videoHeight];
    [self.hlsWriter addAudioStreamWithSampleRate:self.audioSampleRate];
}

- (void)setupEncoders
{
    
    self.h264Encoder = [[KFH264Encoder alloc] initWithBitrate:self.videoBitrate width:self.videoWidth height:self.videoHeight directory:self.folderName];
    self.h264Encoder.delegate = self;
    
    self.aacEncoder = [[KFAACEncoder alloc] initWithBitrate:self.audioBitrate sampleRate:self.audioSampleRate channels:1];
    self.aacEncoder.delegate = self;
    self.aacEncoder.addADTSHeader = YES;
}

- (void)setupAudioCapture
{
    // create capture device with video input
    
    /*
     * Create audio connection
     */
    self.audioQueue = dispatch_queue_create("Audio Capture Queue", DISPATCH_QUEUE_SERIAL);
    self.audioOutput = [[AVCaptureAudioDataOutput alloc] init];
    [self.audioOutput setSampleBufferDelegate:self queue:self.audioQueue];
    if ([self.session canAddOutput:self.audioOutput])
    {
        NSLog(@"Adding audio output.");
        [self.session addOutput:self.audioOutput];
    } else {
        NSLog(@"Unable to add audio output.");
    }
    self.audioConnection = [self.audioOutput connectionWithMediaType:AVMediaTypeAudio];
}

- (void)setupVideoCapture
{
    if(self.isVideoCaptureSetup) {
        NSLog(@"Video already setup, skipping.");
        return;
    }
    // create an output for YUV output with self as delegate
    self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    [self.videoOutput setSampleBufferDelegate:self queue:self.videoQueue];
    NSDictionary *captureSettings = @{(NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    self.videoOutput.videoSettings = captureSettings;
    self.videoOutput.alwaysDiscardsLateVideoFrames = YES;
    if ([self.session canAddOutput:self.videoOutput])
    {
        NSLog(@"Adding video output.");
        [self.session addOutput:self.videoOutput];
    } else {
        NSLog(@"Unable to add video output.");
    }
    self.videoConnection = [self.videoOutput connectionWithMediaType:AVMediaTypeVideo];
    self.isVideoCaptureSetup = YES;
}

- (void)cleanUpCameraInputAndOutput
{
    [self.session removeOutput:self.videoOutput];
    [self.session removeOutput:self.audioOutput];
    [self.session removeInput:self.videoInput];
    [self.session removeInput:self.audioInput];
}

#pragma mark KFEncoderDelegate method
- (void)encoder:(KFEncoder *)encoder encodedFrame:(KFFrame *)frame
{
    if (encoder == self.h264Encoder)
    {
        KFVideoFrame *videoFrame = (KFVideoFrame*)frame;
        CMTime scaledTime = CMTimeSubtract(videoFrame.pts, self.originalSample);
        [self.hlsWriter processEncodedData:videoFrame.data presentationTimestamp:scaledTime streamIndex:0 isKeyFrame:videoFrame.isKeyFrame];
    }
    else if (encoder == self.aacEncoder)
    {
        CMTime scaledTime = CMTimeSubtract(frame.pts, self.originalSample);
        [self.hlsWriter processEncodedData:frame.data presentationTimestamp:scaledTime streamIndex:1 isKeyFrame:NO];
    }
}

#pragma mark AVCaptureOutputDelegate method
- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    
    if (!self.isRecording) return;
    // pass frame to encoders
    if (connection == self.videoConnection)
    {
        CMTime sampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        if (self.originalSample.value == 0)
        {
            self.originalSample = sampleTime;
        }
        self.latestSample = sampleTime;
        [self.h264Encoder encodeSampleBuffer:sampleBuffer];
    }
    else if (connection == self.audioConnection)
    {
        [self.aacEncoder encodeSampleBuffer:sampleBuffer];
    }
}

- (double)durationRecorded
{
    if (self.isRecording)
    {
        return self.currentSegmentDuration + [[NSDate date] timeIntervalSinceDate:self.lastFragmentDate];
    }
    else
    {
        return self.currentSegmentDuration;
    }
}

- (void)setupSession
{
    _videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    self.session = [[AVCaptureSession alloc] init];
    //[self setupVideoCapture];
    //[self setupAudioCapture];
    
    self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
    //self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
}

- (void)startRecording
{
    dispatch_async(self.videoQueue, ^{
        self.lastFragmentDate = [NSDate date];
        self.currentSegmentDuration = 0;
        self.originalSample = CMTimeMakeWithSeconds(0, 0);
        self.latestSample = CMTimeMakeWithSeconds(0, 0);
        
        NSString *segmentName = [self.name stringByAppendingPathComponent:[NSString stringWithFormat:@"segment-%lu-%@", (unsigned long)self.segmentIndex, [Utilities fileNameStringFromDate:[NSDate date]]]];
        [self setupHLSWriterWithName:segmentName];
        self.segmentIndex++;
        
        NSError *error = nil;
        [self.hlsWriter prepareForWriting:&error];
        if (error)
        {
            NSLog(@"Error preparing for writing: %@", error);
        }
        self.isRecording = YES;
        if (self.delegate && [self.delegate respondsToSelector:@selector(recorderDidStartRecording:error:)])
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate recorderDidStartRecording:self error:nil];
            });
        }
    });
    
}

- (void)stopRecording
{
    dispatch_async(self.videoQueue, ^{ // put this on video queue so we don't accidentially write a frame while closing.
        self.isRecording = NO;
        self.directoryWatcher = nil;
        NSError *error = nil;
        [self.hlsWriter finishWriting:&error];
        if (error)
        {
            NSLog(@"Error stop recording: %@", error);
        }
        NSString *fullFolderPath = [[Utilities applicationSupportDirectory] stringByAppendingPathComponent:self.folderName];
        [self postNewFragmentsInManifest:self.hlsWriter.manifestPath]; // update fragments after manifest finalization
        if (self.fileMonitorSource != nil)
        {
            dispatch_source_cancel(self.fileMonitorSource);
            self.fileMonitorSource = nil;
        }
        // clean up the capture*.mp4 files that FFmpeg was reading from, as well as params.mp4
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:fullFolderPath error:nil];
        for (NSString *path in files)
        {
            if ([path hasSuffix:@".mp4"])
            {
                NSString *fullPath = [fullFolderPath stringByAppendingPathComponent:path];
                [[NSFileManager defaultManager] removeItemAtPath:fullPath error:nil];
                //DDLogVerbose(@"Cleaning up by removing %@", fullPath);
            }
        }
        if (self.delegate && [self.delegate respondsToSelector:@selector(recorderDidFinishRecording:error:)])
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate recorderDidFinishRecording:self error:error];
            });
        }
    });
}

@end

