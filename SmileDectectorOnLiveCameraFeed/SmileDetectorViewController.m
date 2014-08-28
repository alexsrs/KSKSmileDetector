//
//  SmileDetectorViewController.m
//  SmileDectectorLiveFeed
//
//  Created by Sanjeeva on 1/28/14.
//  Copyright (c) 2014 Sanjeeva. All rights reserved.
//

#import "SmileDetectorViewController.h"
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <AssertMacros.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <AVFoundation/AVFoundation.h>

static void ReleaseCVPixelBuffer(void *pixel, const void *data, size_t size);
static void ReleaseCVPixelBuffer(void *pixel, const void *data, size_t size)
{
	CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)pixel;
	CVPixelBufferUnlockBaseAddress( pixelBuffer, 0 );
	CVPixelBufferRelease( pixelBuffer );
}

// create a CGImage with provided pixel buffer, pixel buffer must be uncompressed kCVPixelFormatType_32ARGB or kCVPixelFormatType_32BGRA
static OSStatus CreateCGImageFromCVPixelBuffer(CVPixelBufferRef pixelBuffer, CGImageRef *imageOut);
static OSStatus CreateCGImageFromCVPixelBuffer(CVPixelBufferRef pixelBuffer, CGImageRef *imageOut) {
	OSStatus err = noErr;
	OSType sourcePixelFormat;
	size_t width, height, sourceRowBytes;
	void *sourceBaseAddr = NULL;
	CGBitmapInfo bitmapInfo;
	CGColorSpaceRef colorspace = NULL;
	CGDataProviderRef provider = NULL;
	CGImageRef image = NULL;
	
	sourcePixelFormat = CVPixelBufferGetPixelFormatType( pixelBuffer );
	if ( kCVPixelFormatType_32ARGB == sourcePixelFormat )
		bitmapInfo = kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipFirst;
	else if ( kCVPixelFormatType_32BGRA == sourcePixelFormat )
		bitmapInfo = kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst;
	else
		return -95014; // only uncompressed pixel formats
	
	sourceRowBytes = CVPixelBufferGetBytesPerRow( pixelBuffer );
	width = CVPixelBufferGetWidth( pixelBuffer );
	height = CVPixelBufferGetHeight( pixelBuffer );
	
	CVPixelBufferLockBaseAddress( pixelBuffer, 0 );
	sourceBaseAddr = CVPixelBufferGetBaseAddress( pixelBuffer );
	
	colorspace = CGColorSpaceCreateDeviceRGB();
    
	CVPixelBufferRetain( pixelBuffer );
	provider = CGDataProviderCreateWithData( (void *)pixelBuffer, sourceBaseAddr, sourceRowBytes * height, ReleaseCVPixelBuffer);
	image = CGImageCreate(width, height, 8, 32, sourceRowBytes, colorspace, bitmapInfo, provider, NULL, true, kCGRenderingIntentDefault);
	
bail:
	if ( err && image ) {
		CGImageRelease( image );
		image = NULL;
	}
	if ( provider ) CGDataProviderRelease( provider );
	if ( colorspace ) CGColorSpaceRelease( colorspace );
	*imageOut = image;
	return err;
}

// utility used by newSquareOverlayedImageForFeatures for
static CGContextRef CreateCGBitmapContextForSize(CGSize size);
static CGContextRef CreateCGBitmapContextForSize(CGSize size) {
    CGContextRef    context = NULL;
    CGColorSpaceRef colorSpace;
    int             bitmapBytesPerRow;
	
    bitmapBytesPerRow = (size.width * 4);
	
    colorSpace = CGColorSpaceCreateDeviceRGB();
    context = CGBitmapContextCreate (NULL,
									 size.width,
									 size.height,
									 8,      // bits per component
									 bitmapBytesPerRow,
									 colorSpace,
									 kCGImageAlphaPremultipliedLast);
	CGContextSetAllowsAntialiasing(context, NO);
    CGColorSpaceRelease( colorSpace );
    return context;
}

@interface SmileDetectorViewController ()<AVCaptureVideoDataOutputSampleBufferDelegate> {
    AVCaptureStillImageOutput *stillImageOutput;
    AVCaptureVideoPreviewLayer *previewLayer;
	AVCaptureVideoDataOutput *videoDataOutput;
    dispatch_queue_t videoDataOutputQueue;
    CIDetector *faceDetector;
	CGFloat beginGestureScale;
    IBOutlet UIView *previewView;
    CVPixelBufferRef pixelBuffer;
    CIImage *ciImage;
    NSString *hasSmile;
    BOOL isUsingFrontFacingCamera;
    BOOL isEven;
    CALayer *cgrectDraw;
}
@end

@implementation SmileDetectorViewController
#pragma mark View Cycle
- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        // Custom initialization
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view from its nib
    
    [self setUpAVCapture];
    
    CIContext *context = [CIContext contextWithOptions:nil];
    NSDictionary *detectorOptions = @{ CIDetectorAccuracy : CIDetectorAccuracyLow};
    faceDetector = [[CIDetector detectorOfType:CIDetectorTypeFace context:context options:detectorOptions]retain];
}

#pragma mark - SetUp
-(void)setUpAVCapture {
    NSError *error = nil;
    
    AVCaptureSession *session = [AVCaptureSession new];
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone)
	    [session setSessionPreset:AVCaptureSessionPreset640x480];
	else
	    [session setSessionPreset:AVCaptureSessionPresetPhoto];
	
    // Select a video device, make an input
    AVCaptureDevice *device;
    
    AVCaptureDevicePosition desiredPosition = AVCaptureDevicePositionFront;
    for (AVCaptureDevice *d in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
        if ([d position] == desiredPosition) {
            device = d;
            isUsingFrontFacingCamera = YES;
            break;
        }
    }
    // fall back to the default camera.
    if( nil == device )
    {
        device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }
	AVCaptureDeviceInput *deviceInput = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    require( error == nil, bail );
    
    if ( [session canAddInput:deviceInput] )
		[session addInput:deviceInput];
	
    // Make a still image output
	stillImageOutput = [AVCaptureStillImageOutput new];
	if ( [session canAddOutput:stillImageOutput] )
		[session addOutput:stillImageOutput];
	
    // Make a video data output
	videoDataOutput = [AVCaptureVideoDataOutput new];
	
    // we want BGRA, both CoreGraphics and OpenGL work well with 'BGRA'
	NSDictionary *rgbOutputSettings = [NSDictionary dictionaryWithObject:
									   [NSNumber numberWithInt:kCMPixelFormat_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey];
	[videoDataOutput setVideoSettings:rgbOutputSettings];
	[videoDataOutput setAlwaysDiscardsLateVideoFrames:YES]; // discard if the data output queue is blocked (as we process the still image)
    
    // create a serial dispatch queue used for the sample buffer delegate as well as when a still image is captured
    // a serial dispatch queue must be used to guarantee that video frames will be delivered in order
	videoDataOutputQueue = dispatch_queue_create("VideoDataOutputQueue", DISPATCH_QUEUE_SERIAL);
	[videoDataOutput setSampleBufferDelegate:self queue:videoDataOutputQueue];
	
    if ( [session canAddOutput:videoDataOutput] )
		[session addOutput:videoDataOutput];
	[[videoDataOutput connectionWithMediaType:AVMediaTypeVideo] setEnabled:YES];
    
	previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:session];
	[previewLayer setBackgroundColor:[[UIColor blackColor] CGColor]];
	[previewLayer setVideoGravity:AVLayerVideoGravityResizeAspect];
	CALayer *rootLayer = [previewView layer];
	[rootLayer setMasksToBounds:YES];
	[previewLayer setFrame:[rootLayer bounds]];
	[rootLayer addSublayer:previewLayer];
	[session startRunning];
bail:
	[session release];
    if (error) {
		UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:[NSString stringWithFormat:@"Failed with error %d", (int)[error code]]
															message:[error localizedDescription]
														   delegate:nil
												  cancelButtonTitle:@"Dismiss"
												  otherButtonTitles:nil];
		[alertView show];
        [alertView release];
		[self teardownAVCapture];
	}
    
    
}

#pragma mark Delegates
#pragma mark - AVCaptureOutputDelegate
- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
	// got an image
    NSDictionary *imageOptions = nil;
	pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
	CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sampleBuffer, kCMAttachmentMode_ShouldPropagate);
	ciImage = [[CIImage alloc] initWithCVPixelBuffer:pixelBuffer options:(NSDictionary *)attachments];
    
    if (attachments)
		CFRelease(attachments);
    
    UIDeviceOrientation curDeviceOrientation = [[UIDevice currentDevice] orientation];
	int exifOrientation;
	
    /* kCGImagePropertyOrientation values
     The intended display orientation of the image. If present, this key is a CFNumber value with the same value as defined
     by the TIFF and EXIF specifications -- see enumeration of integer constants.
     The value specified where the origin (0,0) of the image is located. If not present, a value of 1 is assumed.
     
     used when calling featuresInImage: options: The value for this key is an integer NSNumber from 1..8 as found in kCGImagePropertyOrientation.
     If present, the detection will be done based on that orientation but the coordinates in the returned features will still be based on those of the image. */
    
	
    exifOrientation = 6;
    
    imageOptions = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:exifOrientation],CIDetectorImageOrientation,@YES,CIDetectorSmile, nil];
	NSArray *features = [faceDetector featuresInImage:ciImage options:imageOptions];
    // get the clean aperture
    // the clean aperture is a rectangle that defines the portion of the encoded pixel dimensions
    // that represents image data valid for display.
	CMFormatDescriptionRef fdesc = CMSampleBufferGetFormatDescription(sampleBuffer);
	CGRect clap = CMVideoFormatDescriptionGetCleanAperture(fdesc, false /*originIsTopLeft == false*/);
	
	
    dispatch_async(dispatch_get_main_queue(), ^{
        [self parseFeatures:features forVideoBox:clap orientation:curDeviceOrientation];
    });
    [ciImage release];
    
}

#pragma mark - Parse Features

-(void)parseFeatures:(NSArray*)features forVideoBox:(CGRect)clap orientation:(UIDeviceOrientation)curDeviceOrientation {
    
    NSArray *sublayers = [NSArray arrayWithArray:[previewLayer sublayers]];
	NSInteger sublayersCount = [sublayers count], currentSublayer = 0;
	NSInteger currentFeature = 0;
    
    for ( CALayer *layer in sublayers ) {
		if ( [[layer name] isEqualToString:@"FaceLayer"] )
			[layer setHidden:YES];
	}
    CGSize parentFrameSize = [previewView frame].size;
	NSString *gravity = [previewLayer videoGravity];
	BOOL isMirrored = [previewLayer isMirrored];
	CGRect previewBox = [SmileDetectorViewController videoPreviewBoxForGravity:gravity
                                                                     frameSize:parentFrameSize
                                                                  apertureSize:clap.size];
    
    
    for(CIFaceFeature *faceFeature in features)
    {
        hasSmile = faceFeature.hasSmile ? @"Yes" : @"No";
        
        CGRect faceRect = [faceFeature bounds];
        
		// flip preview width and height
		CGFloat temp = faceRect.size.width;
		faceRect.size.width = faceRect.size.height;
		faceRect.size.height = temp;
		temp = faceRect.origin.x;
		faceRect.origin.x = faceRect.origin.y;
		faceRect.origin.y = temp;
		// scale coordinates so they fit in the preview box, which may be scaled
		CGFloat widthScaleBy = previewBox.size.width / clap.size.height;
		CGFloat heightScaleBy = previewBox.size.height / clap.size.width;
		faceRect.size.width *= widthScaleBy;
		faceRect.size.height *= heightScaleBy;
		faceRect.origin.x *= widthScaleBy;
		faceRect.origin.y *= heightScaleBy;
        
		if ( isMirrored )
			faceRect = CGRectOffset(faceRect, previewBox.origin.x + previewBox.size.width - faceRect.size.width - (faceRect.origin.x * 2), previewBox.origin.y);
		else
			faceRect = CGRectOffset(faceRect, previewBox.origin.x, previewBox.origin.y);
        
        
        CALayer *featureLayer = nil;
		
		// re-use an existing layer if possible
		while ( !featureLayer && (currentSublayer < sublayersCount) ) {
			CALayer *currentLayer = [sublayers objectAtIndex:currentSublayer++];
			if ( [[currentLayer name] isEqualToString:@"FaceLayer"] ) {
				featureLayer = currentLayer;
                if(faceFeature.hasSmile){
                    [featureLayer setBorderColor:[UIColor greenColor].CGColor];
                }else{
                    [featureLayer setBorderColor:[UIColor redColor].CGColor];
                }
				[currentLayer setHidden:NO];
			}
		}
		
		// create a new one if necessary
		if ( !featureLayer ) {
			featureLayer = [CALayer new];
			[featureLayer setMasksToBounds:NO];
            [featureLayer setBorderWidth:8];
            if(faceFeature.hasSmile){
                [featureLayer setBorderColor:[UIColor greenColor].CGColor];
            }else{
                [featureLayer setBorderColor:[UIColor redColor].CGColor];
            }
			[featureLayer setName:@"FaceLayer"];
			[previewLayer addSublayer:featureLayer];
			[featureLayer release];
		}
		[featureLayer setFrame:faceRect];
		currentFeature++;
    }
}
// find where the video box is positioned within the preview layer based on the video size and gravity
+ (CGRect)videoPreviewBoxForGravity:(NSString *)gravity frameSize:(CGSize)frameSize apertureSize:(CGSize)apertureSize
{
    CGFloat apertureRatio = apertureSize.height / apertureSize.width;
    CGFloat viewRatio = frameSize.width / frameSize.height;
    
    CGSize size = CGSizeZero;
    if ([gravity isEqualToString:AVLayerVideoGravityResizeAspectFill]) {
        if (viewRatio > apertureRatio) {
            size.width = frameSize.width;
            size.height = apertureSize.width * (frameSize.width / apertureSize.height);
        } else {
            size.width = apertureSize.height * (frameSize.height / apertureSize.width);
            size.height = frameSize.height;
        }
    } else if ([gravity isEqualToString:AVLayerVideoGravityResizeAspect]) {
        if (viewRatio > apertureRatio) {
            size.width = apertureSize.height * (frameSize.height / apertureSize.width);
            size.height = frameSize.height;
        } else {
            size.width = frameSize.width;
            size.height = apertureSize.width * (frameSize.width / apertureSize.height);
        }
    } else if ([gravity isEqualToString:AVLayerVideoGravityResize]) {
        size.width = frameSize.width;
        size.height = frameSize.height;
    }
	
	CGRect videoBox;
	videoBox.size = size;
	if (size.width < frameSize.width)
		videoBox.origin.x = (frameSize.width - size.width) / 2;
	else
		videoBox.origin.x = (size.width - frameSize.width) / 2;
	
	if ( size.height < frameSize.height )
		videoBox.origin.y = (frameSize.height - size.height) / 2;
	else
		videoBox.origin.y = (size.height - frameSize.height) / 2;
    
	return videoBox;
}

// utility routine to display error aleart if takePicture fails
- (void)displayErrorOnMainQueue:(NSError *)error withMessage:(NSString *)message
{
	dispatch_async(dispatch_get_main_queue(), ^(void) {
		UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:[NSString stringWithFormat:@"%@ (%d)", message, (int)[error code]]
															message:[error localizedDescription]
														   delegate:nil
												  cancelButtonTitle:@"Dismiss"
												  otherButtonTitles:nil];
		[alertView show];
		[alertView release];
	});
}

#pragma mark - Take Picture
// main action method to take a still image -- if face detection has been turned on and a face has been detected
// the square overlay will be composited on top of the captured image and saved to the camera roll
- (void)takePicture
{
    // Find out the current orientation and tell the still image output.
	AVCaptureConnection *stillImageConnection = [stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
	UIDeviceOrientation curDeviceOrientation = [[UIDevice currentDevice] orientation];
    AVCaptureVideoOrientation avcaptureOrientation = (AVCaptureVideoOrientation) curDeviceOrientation;
	[stillImageConnection setVideoOrientation:avcaptureOrientation];
	[stillImageConnection setVideoScaleAndCropFactor:1.0];
	
	
    // set the appropriate pixel format / image type output setting depending on if we'll need an uncompressed image for
    // the possiblity of drawing the red square over top or if we're just writing a jpeg to the camera roll which is the trival case
    
    [stillImageOutput setOutputSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCMPixelFormat_32BGRA]
                                                                    forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
	
	[stillImageOutput captureStillImageAsynchronouslyFromConnection:stillImageConnection
                                                  completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
                                                      if (error) {
                                                          [self displayErrorOnMainQueue:error withMessage:@"Take picture failed"];
                                                      }
                                                      else {
                                                          // Got an image.
                                                          CVPixelBufferRef pixelBuffe = CMSampleBufferGetImageBuffer(imageDataSampleBuffer);
                                                          CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, imageDataSampleBuffer, kCMAttachmentMode_ShouldPropagate);
                                                          CIImage *ciImag = [[CIImage alloc] initWithCVPixelBuffer:pixelBuffe options:(NSDictionary *)attachments];
                                                          if (attachments)
                                                              CFRelease(attachments);
                                                          
                                                          NSDictionary *imageOptions = nil;
                                                          NSNumber *orientation = CMGetAttachment(imageDataSampleBuffer, kCGImagePropertyOrientation, NULL);
                                                          if (orientation) {
                                                              imageOptions = [NSDictionary dictionaryWithObject:orientation forKey:CIDetectorImageOrientation];
                                                          }
                                                          
                                                          // when processing an existing frame we want any new frames to be automatically dropped
                                                          // queueing this block to execute on the videoDataOutputQueue serial queue ensures this
                                                          dispatch_sync(videoDataOutputQueue, ^(void) {
                                                              
                                                              // get the array of CIFeature instances in the given image with a orientation passed in
                                                              // the detection will be done based on the orientation but the coordinates in the returned features will
                                                              // still be based on those of the image.
                                                              NSArray *features = [faceDetector featuresInImage:ciImag options:imageOptions];
                                                              CGImageRef srcImage = NULL;
                                                              OSStatus err = CreateCGImageFromCVPixelBuffer(CMSampleBufferGetImageBuffer(imageDataSampleBuffer), &srcImage);
                                                              check(!err);
                                                              
                                                              CGImageRef cgImageResult = [self newSquareOverlayedImageForFeatures:features
                                                                                                                        inCGImage:srcImage
                                                                                                                  withOrientation:curDeviceOrientation
                                                                                                                      frontFacing:isUsingFrontFacingCamera];
                                                              if (srcImage)
                                                                  CFRelease(srcImage);
                                                              
                                                              CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault,
                                                                                                                          imageDataSampleBuffer,
                                                                                                                          kCMAttachmentMode_ShouldPropagate);
                                                              [self writeCGImageToCameraRoll:cgImageResult withMetadata:(id)attachments];
                                                              if (attachments)
                                                                  CFRelease(attachments);
                                                              if (cgImageResult)
                                                                  CFRelease(cgImageResult);
                                                              
                                                          });
                                                          
                                                          [ciImag release];
                                                      }
                                                  }
	 ];
}

- (CGImageRef)newSquareOverlayedImageForFeatures:(NSArray *)features
                                       inCGImage:(CGImageRef)backgroundImage
                                 withOrientation:(UIDeviceOrientation)orientation
                                     frontFacing:(BOOL)isFrontFacing
{
	CGImageRef returnImage = NULL;
	CGRect backgroundImageRect = CGRectMake(0., 0., CGImageGetWidth(backgroundImage), CGImageGetHeight(backgroundImage));
	CGContextRef bitmapContext = CreateCGBitmapContextForSize(backgroundImageRect.size);
	CGContextClearRect(bitmapContext, backgroundImageRect);
	CGContextDrawImage(bitmapContext, backgroundImageRect, backgroundImage);
	
	returnImage = CGBitmapContextCreateImage(bitmapContext);
	CGContextRelease (bitmapContext);
	
	return returnImage;
}
- (BOOL)writeCGImageToCameraRoll:(CGImageRef)cgImage withMetadata:(NSDictionary *)metadata
{
	CFMutableDataRef destinationData = CFDataCreateMutable(kCFAllocatorDefault, 0);
	CGImageDestinationRef destination = CGImageDestinationCreateWithData(destinationData,
																		 CFSTR("public.jpeg"),
																		 1,
																		 NULL);
	BOOL success = (destination != NULL);
	require(success, bail);
    
	const float JPEGCompQuality = 0.85f; // JPEGHigherQuality
	CFMutableDictionaryRef optionsDict = NULL;
	CFNumberRef qualityNum = NULL;
	
	qualityNum = CFNumberCreate(0, kCFNumberFloatType, &JPEGCompQuality);
	if ( qualityNum ) {
		optionsDict = CFDictionaryCreateMutable(0, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		if ( optionsDict )
			CFDictionarySetValue(optionsDict, kCGImageDestinationLossyCompressionQuality, qualityNum);
		CFRelease( qualityNum );
	}
	
	CGImageDestinationAddImage( destination, cgImage, optionsDict );
	success = CGImageDestinationFinalize( destination );
    
	if ( optionsDict )
		CFRelease(optionsDict);
	
	require(success, bail);
	
	CFRetain(destinationData);
	ALAssetsLibrary *library = [ALAssetsLibrary new];
	[library writeImageDataToSavedPhotosAlbum:(id)destinationData metadata:metadata completionBlock:^(NSURL *assetURL, NSError *error) {
		if (destinationData)
			CFRelease(destinationData);
	}];
	[library release];
    
    
bail:
	if (destinationData)
		CFRelease(destinationData);
	if (destination)
		CFRelease(destination);
	return success;
}

#pragma mark Button Actions
- (IBAction)captureButtonTapped:(id)sender {
    [self takePicture];
}
- (IBAction)switchCameras:(id)sender
{
	AVCaptureDevicePosition desiredPosition;
	if (isUsingFrontFacingCamera)
		desiredPosition = AVCaptureDevicePositionBack;
	else
		desiredPosition = AVCaptureDevicePositionFront;
	
	for (AVCaptureDevice *d in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
		if ([d position] == desiredPosition) {
			[[previewLayer session] beginConfiguration];
			AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:d error:nil];
			for (AVCaptureInput *oldInput in [[previewLayer session] inputs]) {
				[[previewLayer session] removeInput:oldInput];
			}
			[[previewLayer session] addInput:input];
			[[previewLayer session] commitConfiguration];
			break;
		}
	}
	isUsingFrontFacingCamera = !isUsingFrontFacingCamera;
}
#pragma mark Deallocs
- (void)teardownAVCapture
{
	[videoDataOutput release];
	if (videoDataOutputQueue)
		dispatch_release(videoDataOutputQueue);
	[stillImageOutput removeObserver:self forKeyPath:@"isCapturingStillImage"];
	[stillImageOutput release];
	[previewLayer removeFromSuperlayer];
	[previewLayer release];
}
- (void)dealloc
{
	[self teardownAVCapture];
	[faceDetector release];
	[super dealloc];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

@end
