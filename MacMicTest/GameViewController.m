//
//  GameViewController.m
//  MacMicTest
//
//  Created by ringo on 2023/09/21.
//
//
//
// macOSでオーディオデバイスを使うためのnpmにはspeakerやsox,node-record-lcpm16などがあるが、
// Intel環境を必要とするとか、特定のNodeバージョンで動かない問題があったので、
// C言語で独自に実装して、nodeのFFIから使うことにした。
// これは、そのライブラリを実装するための準備用の動作テスト用のプロジェクト。


#import "GameViewController.h"
#import "Renderer.h"



#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

#define kNumberBuffers 3

int g_echoback=1; // これを1 にすると、エコーバックする(ハウリングに注意)


/*
 SampleBuffer
 サンプルデータを格納しておく構造体
 
 */
typedef struct
{
#define SAMPLE_MAX 24000
    short samples[SAMPLE_MAX];
    int used;
} SampleBuffer;

SampleBuffer *g_recbuf; // 録音したサンプルデータ
SampleBuffer *g_playbuf; // 再生予定のサンプルデータ

// 必要なSampleBufferを初期化する
static void initSampleBuffers() {
    g_recbuf = (SampleBuffer*) malloc(sizeof(SampleBuffer));
    memset(g_recbuf,0,sizeof(SampleBuffer));
    g_playbuf = (SampleBuffer*) malloc(sizeof(SampleBuffer));
    memset(g_playbuf,0,sizeof(SampleBuffer));
}

static int shiftSamples(SampleBuffer *buf, short *output, int num) {
    int to_output=num;
    if(to_output>buf->used) to_output=buf->used;
    // output
    if(output) for(int i=0;i<to_output;i++) output[i]=buf->samples[i];
    // shift
    int to_shift=buf->used-to_output;
    for(int i=to_output;i<buf->used;i++) buf->samples[i-to_output]=buf->samples[i];
    buf->used-=to_output;
    fprintf(stderr,"shiftSamples: buf used: %d\n",buf->used);
    return to_output;
}
static void pushSamples(SampleBuffer *buf,short *append, int num) {
    if(buf->used+num>SAMPLE_MAX) shiftSamples(buf,NULL,num);
    for(int i=0;i<num;i++) {
        buf->samples[i+buf->used]=append[i];
    }
    buf->used+=num;
    fprintf(stderr,"pushSamples: g_samples_used: %d\n",buf->used);
}


/*--------*/

// AudioQueueRefとその他の情報を格納
typedef struct {
    AudioStreamBasicDescription dataFormat;
    AudioQueueRef queue;
    AudioQueueBufferRef buffers[kNumberBuffers];
} RecordState;

// コールバック関数
static void HandleInputBuffer(
    void *inUserData,
    AudioQueueRef inAQ,
    AudioQueueBufferRef inBuffer,
    const AudioTimeStamp *inStartTime,
    UInt32 inNumPackets,
    const AudioStreamPacketDescription *inPacketDesc
) {
    RecordState *recordState = (RecordState *)inUserData;
    // inBufferには録音データが入っているので、ここで処理を行う
    if (inNumPackets > 0) {
        short *audioData = (short *)inBuffer->mAudioData;
        int tot=0;
        for (int i = 0; i < 5 && i < inNumPackets; i++) {
            tot+=audioData[i];
        }
        printf("tot: %d %d\n", tot, inNumPackets);
        pushSamples(g_recbuf,audioData,inNumPackets);
        if(g_echoback) pushSamples(g_playbuf,audioData,inNumPackets);
    }
    
    // バッファを再度エンキュー
    OSStatus st= AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
    if(st!=noErr) {
        printf("AudioQueueEnqueueBuffer fail:%d\n",st);
    }
}

extern int startMic(void);

int startMic() {
    @autoreleasepool {
        RecordState recordState;
        memset(&recordState, 0, sizeof(RecordState));

        // オーディオデータフォーマットの設定
        recordState.dataFormat.mSampleRate = 24000;
        recordState.dataFormat.mFormatID = kAudioFormatLinearPCM;
        recordState.dataFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
        recordState.dataFormat.mBytesPerPacket = 2;
        recordState.dataFormat.mFramesPerPacket = 1;
        recordState.dataFormat.mBytesPerFrame = 2;
        recordState.dataFormat.mChannelsPerFrame = 1;
        recordState.dataFormat.mBitsPerChannel = 16;


        // オーディオキューの作成
        OSStatus st=AudioQueueNewInput(&recordState.dataFormat, HandleInputBuffer, &recordState, NULL, kCFRunLoopCommonModes, 0, &recordState.queue);
        if(st!=noErr) return st;

        // バッファの確保とエンキュー
        for (int i = 0; i < kNumberBuffers; ++i) {
            AudioQueueAllocateBuffer(recordState.queue, 4096, &recordState.buffers[i]);
            AudioQueueEnqueueBuffer(recordState.queue, recordState.buffers[i], 0, NULL);
        }

        // 録音開始
        st=AudioQueueStart(recordState.queue, NULL);
        if(st!=noErr) return st;
    }
    return 0;
}




int listDevices() {
    @autoreleasepool {
        AudioObjectPropertyAddress propertyAddress = {
            kAudioHardwarePropertyDevices,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMaster
        };

        UInt32 dataSize = 0;
        OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize);
        if (status != noErr) {
            NSLog(@"Error %d getting devices' data size", status);
            return 1;
        }

        UInt32 deviceCount = dataSize / sizeof(AudioDeviceID);
        AudioDeviceID *audioDevices = malloc(dataSize);
        
        status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize, audioDevices);
        if (status != noErr) {
            NSLog(@"Error %d getting devices' data", status);
            return 1;
        }

        for (UInt32 i = 0; i < deviceCount; ++i) {
            AudioDeviceID deviceID = audioDevices[i];

            CFStringRef deviceName = NULL;
            dataSize = sizeof(deviceName);
            propertyAddress.mSelector = kAudioDevicePropertyDeviceNameCFString;

            status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, NULL, &dataSize, &deviceName);
            if (status == noErr) {
                NSLog(@"Device ID: %u, Name: %@", deviceID, deviceName);
                CFRelease(deviceName);
            } else {
                NSLog(@"Error %d getting device name", status);
            }
        }

        free(audioDevices);
    }
    return 0;
}


int checkOutputDevice(int channelNum, int sampleRate) {
    @autoreleasepool {
        // デフォルトの出力デバイスを取得
        AudioObjectPropertyAddress propertyAddress = {
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMaster
        };
        AudioDeviceID outputDeviceID = kAudioDeviceUnknown;
        UInt32 dataSize = sizeof(outputDeviceID);
        OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propertyAddress, 3, NULL, &dataSize, &outputDeviceID);
        if (status != noErr) {
            NSLog(@"Error getting default output device: %d", status);
            return 1;
        }
        fprintf(stderr,"outputdeviceid:%d datasize:%d\n",outputDeviceID,dataSize);
        
        // サポートされているフォーマットを取得（ここでは例として kAudioFormatLinearPCM を使用）
        propertyAddress.mSelector = kAudioDevicePropertyStreamFormats;
        propertyAddress.mScope = kAudioDevicePropertyScopeOutput;
        status = AudioObjectGetPropertyDataSize(outputDeviceID, &propertyAddress, 0, NULL, &dataSize);
        if (status != noErr) {
            NSLog(@"Error getting stream formats data size: %d", status);
            return 1;
        }

        AudioStreamBasicDescription *formats = malloc(dataSize);
        status = AudioObjectGetPropertyData(outputDeviceID, &propertyAddress, 0, NULL, &dataSize, formats);
        if (status != noErr) {
            NSLog(@"Error getting stream formats: %d", status);
            return 1;
        }

        UInt32 numFormats = dataSize / sizeof(AudioStreamBasicDescription);
        BOOL isSupported = NO;
        for (UInt32 i = 0; i < numFormats; ++i) {
            int flag=formats[i].mFormatFlags;
            int isFloat = flag & kAudioFormatFlagIsFloat;
            int isBigEndian = flag & kAudioFormatFlagIsBigEndian;
            int isSignedInt = flag & kAudioFormatFlagIsSignedInteger;
            int isPacked = flag & kAudioFormatFlagIsPacked;
            int isAlignedHigh = flag & kAudioFormatFlagIsAlignedHigh;
            int isNonInterleaved = flag & kAudioFormatFlagIsNonInterleaved;
            int isNonMixable = flag & kAudioFormatFlagIsNonMixable;
            int isAllClear = flag & kAudioFormatFlagsAreAllClear;
            // formatId: 1819304813 'lpcm'
            printf("format %d: id:%d rate:%f ch:%d flag:%d float:%d big:%d sign:%d packed:%d \n", i,
                   formats[i].mFormatID, formats[i].mSampleRate, formats[i].mChannelsPerFrame, formats[i].mFormatFlags,
                   isFloat, isBigEndian,isSignedInt,isPacked);
            if (formats[i].mFormatID == kAudioFormatLinearPCM &&
                formats[i].mSampleRate == sampleRate &&
                formats[i].mChannelsPerFrame == channelNum &&
                isFloat && isPacked ) {
                isSupported = YES;
            }
        }
        
        if (isSupported) {
            NSLog(@"The specified format is supported.");
        } else {
            NSLog(@"The specified format is not supported.");
        }

        free(formats);
        return isSupported;
    }
}



/*------*/
static OSStatus RenderCallback(void *inRefCon,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp *inTimeStamp,
                               UInt32 inBusNumber,
                               UInt32 inNumberFrames,
                               AudioBufferList *ioData)
{
    static short tmp[256];
    int n=256;
    int shifted=shiftSamples(g_playbuf,tmp,n);
    printf("render inNumberFrames:%d shifted:%d tmp0:%d\n",inNumberFrames,shifted,tmp[0]);
      
    SInt16 *outFrames = (SInt16*)(ioData->mBuffers->mData);
    for(int i=0;i<inNumberFrames;i++) {
        short sample=0;
        if(i<shifted)sample=tmp[i];
        outFrames[i]=sample;
    }
    return noErr;
}

void startSpeaker() {

    AudioComponentInstance audioUnit;
    AudioComponentDescription desc;

    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_DefaultOutput;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;

    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    AudioComponentInstanceNew(comp, &audioUnit);

    // チャンネル数を設定
    AudioStreamBasicDescription audioFormat;
    memset(&audioFormat, 0, sizeof(AudioStreamBasicDescription));
    audioFormat.mSampleRate = 24000;
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    audioFormat.mFramesPerPacket = 1;
    audioFormat.mChannelsPerFrame = 1;
    audioFormat.mBitsPerChannel = 16;
    audioFormat.mBytesPerFrame = 2;
    audioFormat.mBytesPerPacket = 2;

    OSStatus status = AudioUnitSetProperty(audioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input,
                                  0,
                                  &audioFormat,
                                  sizeof(AudioStreamBasicDescription));

    if (status != noErr) {
        fprintf(stderr,"streamformat set error:%d\n",status);
    }
    
    
    
    
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = RenderCallback;
    callbackStruct.inputProcRefCon = audioUnit;

    OSStatus st2=AudioUnitSetProperty(audioUnit,
                         kAudioUnitProperty_SetRenderCallback,
                         kAudioUnitScope_Output,
                         0,
                         &callbackStruct,
                         sizeof(callbackStruct));
    fprintf(stderr,"setrendercb: ret:%d\n",st2);

    AudioUnitInitialize(audioUnit);
    AudioOutputUnitStart(audioUnit);

/*
    AudioOutputUnitStop(audioUnit);
    AudioUnitUninitialize(audioUnit);
    AudioComponentInstanceDispose(audioUnit);
*/

}

/*--------------------------------------*/
@implementation GameViewController
{
    MTKView *_view;

    Renderer *_renderer;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    _view = (MTKView *)self.view;

    _view.device = MTLCreateSystemDefaultDevice();

    if(!_view.device)
    {
        NSLog(@"Metal is not supported on this device");
        self.view = [[NSView alloc] initWithFrame:self.view.frame];
        return;
    }

    _renderer = [[Renderer alloc] initWithMetalKitView:_view];

    [_renderer mtkView:_view drawableSizeWillChange:_view.bounds.size];

    _view.delegate = _renderer;
    
    listDevices();
    checkOutputDevice(2,48000);
    initSampleBuffers();
    startMic();
    startSpeaker();
}

@end
