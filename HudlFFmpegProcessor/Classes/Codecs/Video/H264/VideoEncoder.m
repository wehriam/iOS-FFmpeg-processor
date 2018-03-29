//
//  VideoEncoder.m
//  Encoder Demo
//
//  Created by Geraint Davies on 14/01/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//

#import "VideoEncoder.h"

@implementation VideoEncoder

@synthesize path = _path;

+ (VideoEncoder *)encoderForPath:(NSString*) path height:(int)height width:(int)width bitrate:(int)bitrate
{
    VideoEncoder *enc = [VideoEncoder alloc];
    [enc initPath:path height:height width:width bitrate:bitrate];
    return enc;
}

- (void)initPath:(NSString*)path height:(int)height width:(int)width bitrate:(int)bitrate
{
    self.path = path;
    _bitrate = bitrate;
    
    [[NSFileManager defaultManager] removeItemAtPath:self.path error:nil];
    NSURL* url = [NSURL fileURLWithPath:self.path];
    
    _writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeMPEG4 error:nil];
    NSDictionary* settings = @{
        AVVideoCodecKey: AVVideoCodecH264,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: @{
             AVVideoExpectedSourceFrameRateKey: @(24),
             AVVideoAverageBitRateKey: @(self.bitrate),
             AVVideoMaxKeyFrameIntervalKey: @(30),
             AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
             AVVideoAllowFrameReorderingKey: @NO,
        }
    };
    _writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    _writerInput.expectsMediaDataInRealTime = YES;
    [_writer addInput:_writerInput];
}

- (void) finishWithCompletionHandler:(void (^)(void))handler
{
    if (_writer.status == AVAssetWriterStatusWriting)
    {
        [_writer finishWritingWithCompletionHandler: handler];
    }
}

- (BOOL) encodeFrame:(CMSampleBufferRef) sampleBuffer
{
    if (CMSampleBufferDataIsReady(sampleBuffer))
    {
        if (_writer.status == AVAssetWriterStatusUnknown)
        {
            CMTime startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            [_writer startWriting];
            [_writer startSessionAtSourceTime:startTime];
        }
        if (_writer.status == AVAssetWriterStatusFailed)
        {
            //DDLogVerbose(@"writer error %@", _writer.error);
            return NO;
        }
        if (_writerInput.readyForMoreMediaData == YES)
        {
            [_writerInput appendSampleBuffer:sampleBuffer];
            return YES;
        }
    }
    return NO;
}

@end
