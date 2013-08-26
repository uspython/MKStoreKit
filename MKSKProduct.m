//
//  MKSKProduct.m
//  MKStoreKit (Version 5.0)
//
//  Created by Mugunth Kumar (@mugunthkumar) on 04/07/11.
//  Copyright (C) 2011-2020 by Steinlogic Consulting And Training Pte Ltd.

//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

//  As a side note on using this code, you might consider giving some credit to me by
//	1) linking my website from your app's website
//	2) or crediting me inside the app's credits page
//	3) or a tweet mentioning @mugunthkumar
//	4) A paypal donation to mugunth.kumar@gmail.com

#import "MKSKProduct.h"
#import "AXSConnect.h"
#import "CAQIUtility.h"
#import "NSData+MKBase64.h"
#import "WMUCTranscation.h"

#if ! __has_feature(objc_arc)
#error MKStoreKit is ARC only. Either turn on ARC for the project or use -fobjc-arc flag
#endif

#ifndef __IPHONE_5_0
#error "MKStoreKit uses features (NSJSONSerialization) only available in iOS SDK  and later."
#endif

static void (^onReviewRequestVerificationSucceeded)();
static void (^onReviewRequestVerificationFailed)();
static NSURLConnection *sConnection;
static NSMutableData *sDataFromConnection;
//static WMRequest *requestWMS;

@interface MKSKProduct ()
{
    int retryCount;
}

@end

@implementation MKSKProduct

+(NSString*) deviceId {
  
#if TARGET_OS_IPHONE
  NSString *uniqueID;
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  id uuid = [defaults objectForKey:@"uniqueID"];
  if (uuid)
    uniqueID = (NSString *)uuid;
  else {
    CFUUIDRef cfUuid = CFUUIDCreate(NULL);
    CFStringRef cfUuidString = CFUUIDCreateString(NULL, cfUuid);
    CFRelease(cfUuid);
    uniqueID = (__bridge NSString *)cfUuidString;
    [defaults setObject:uniqueID forKey:@"uniqueID"];
    CFRelease(cfUuidString);
  }
  
  return uniqueID;
#elif TARGET_OS_MAC 
  
  kern_return_t			 kernResult;
	mach_port_t			   master_port;
	CFMutableDictionaryRef	matchingDict;
	io_iterator_t			 iterator;
	io_object_t			   service;
	CFDataRef				 macAddress = nil;
  
	kernResult = IOMasterPort(MACH_PORT_NULL, &master_port);
	if (kernResult != KERN_SUCCESS) {
		printf("IOMasterPort returned %d\n", kernResult);
		return nil;
	}
  
	matchingDict = IOBSDNameMatching(master_port, 0, "en0");
	if(!matchingDict) {
		printf("IOBSDNameMatching returned empty dictionary\n");
		return nil;
	}
  
	kernResult = IOServiceGetMatchingServices(master_port, matchingDict, &iterator);
	if (kernResult != KERN_SUCCESS) {
		printf("IOServiceGetMatchingServices returned %d\n", kernResult);
		return nil;
	}
  
	while((service = IOIteratorNext(iterator)) != 0)
	{
		io_object_t		parentService;
    
		kernResult = IORegistryEntryGetParentEntry(service, kIOServicePlane, &parentService);
		if(kernResult == KERN_SUCCESS)
		{
      if(macAddress)
        CFRelease(macAddress);
			macAddress = IORegistryEntryCreateCFProperty(parentService, CFSTR("IOMACAddress"), kCFAllocatorDefault, 0);
			IOObjectRelease(parentService);
		}
		else {
			printf("IORegistryEntryGetParentEntry returned %d\n", kernResult);
		}
    
		IOObjectRelease(service);
	}
  
	return [[NSString alloc] initWithData:(__bridge NSData*) macAddress encoding:NSASCIIStringEncoding];
#endif
}

-(id) initWithProductId:(NSString*) aProductId receiptData:(NSData*) aReceipt
{
  if((self = [super init]))
  {
    self.productId = aProductId;
    self.receipt = aReceipt;
    retryCount = 0;
  }
  return self;
}

-(id) initWithProductId:(NSString*) aProductId receiptData:(NSData*) aReceipt andSerialNum:(NSString*)aSerial
{
    if((self = [self initWithProductId:aProductId receiptData:aReceipt ]))
    {
        self.serialNum = aSerial;
    }
    return self;
}

#pragma mark -
#pragma mark In-App purchases promo codes support
// This function is only used if you want to enable in-app purchases for free for reviewers
// Read my blog post http://mk.sg/31

+(void) verifyProductForReviewAccess:(NSString*) productId
                          onComplete:(void (^)(NSNumber*)) completionBlock
                             onError:(void (^)(NSError*)) errorBlock
{
  if(REVIEW_ALLOWED)
  {
    onReviewRequestVerificationSucceeded = [completionBlock copy];
    onReviewRequestVerificationFailed = [errorBlock copy];
    
    NSString *uniqueID = [self deviceId];
    // check udid and featureid with developer's server
		
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@", OWN_SERVER, @"featureCheck.php"]];
    
    NSMutableURLRequest *theRequest = [NSMutableURLRequest requestWithURL:url 
                                                              cachePolicy:NSURLRequestReloadIgnoringCacheData 
                                                          timeoutInterval:60];
    
    [theRequest setHTTPMethod:@"POST"];		
    [theRequest setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    
    NSString *postData = [NSString stringWithFormat:@"productid=%@&udid=%@", productId, uniqueID];
    
    NSString *length = [NSString stringWithFormat:@"%d", [postData length]];	
    [theRequest setValue:length forHTTPHeaderField:@"Content-Length"];	
    
    [theRequest setHTTPBody:[postData dataUsingEncoding:NSASCIIStringEncoding]];
    
    sConnection = [NSURLConnection connectionWithRequest:theRequest delegate:self];    
    [sConnection start];	
  }
  else
  {
    completionBlock([NSNumber numberWithBool:NO]);
  }
}

- (void) verifyReceiptOnComplete:(void (^)(NSNumber*)) completionBlock
                         onError:(void (^)(NSError*)) errorBlock
{
  self.onReceiptVerificationSucceeded = completionBlock;
  self.onReceiptVerificationFailed = errorBlock;
  
  NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@", OWN_SERVER, @"verifyProduct.php"]];
	
	NSMutableURLRequest *theRequest = [NSMutableURLRequest requestWithURL:url 
                                                            cachePolicy:NSURLRequestReloadIgnoringCacheData 
                                                        timeoutInterval:60];
	
	[theRequest setHTTPMethod:@"POST"];		
	[theRequest setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
	
	NSString *receiptDataString = [self.receipt base64EncodedString];
  
	NSString *postData = [NSString stringWithFormat:@"receiptdata=%@", receiptDataString];
	
	NSString *length = [NSString stringWithFormat:@"%d", [postData length]];	
	[theRequest setValue:length forHTTPHeaderField:@"Content-Length"];	
	
	[theRequest setHTTPBody:[postData dataUsingEncoding:NSASCIIStringEncoding]];
	
  self.theConnection = [NSURLConnection connectionWithRequest:theRequest delegate:self];    
  [self.theConnection start];	
}


#pragma mark -
#pragma mark NSURLConnection delegate

- (void)connection:(NSURLConnection *)connection
didReceiveResponse:(NSURLResponse *)response
{	
  //self.dataFromConnection = [NSMutableData data];
}

- (void)connection:(NSURLConnection *)connection
    didReceiveData:(NSData *)data
{
	//[self.dataFromConnection appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
//  NSString *responseString = [[NSString alloc] initWithData:self.dataFromConnection 
//                                                   encoding:NSASCIIStringEncoding];
//  responseString = [responseString stringByTrimmingCharactersInSet:
//                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
//  self.dataFromConnection = nil;
//	if([responseString isEqualToString:@"YES"])		
//	{
//    if(self.onReceiptVerificationSucceeded)
//    {
//      self.onReceiptVerificationSucceeded();
//      self.onReceiptVerificationSucceeded = nil;
//    }
//	}
//  else
//  {
//    if(self.onReceiptVerificationFailed)
//    {
//      self.onReceiptVerificationFailed(nil);
//      self.onReceiptVerificationFailed = nil;
//    }
//  }
	
  
}


- (void)connection:(NSURLConnection *)connection
  didFailWithError:(NSError *)error
{
  
//  self.dataFromConnection = nil;
//  if(self.onReceiptVerificationFailed)
//  {
//    self.onReceiptVerificationFailed(error);
//    self.onReceiptVerificationFailed = nil;
//  }
}



+ (void)connection:(NSURLConnection *)connection
didReceiveResponse:(NSURLResponse *)response
{	
  sDataFromConnection = [[NSMutableData alloc] init];
}

+ (void)connection:(NSURLConnection *)connection
    didReceiveData:(NSData *)data
{
	[sDataFromConnection appendData:data];
}

+ (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
  NSString *responseString = [[NSString alloc] initWithData:sDataFromConnection 
                                                   encoding:NSASCIIStringEncoding];
  responseString = [responseString stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  sDataFromConnection = nil;
  
	if([responseString isEqualToString:@"YES"])		
	{
    if(onReviewRequestVerificationSucceeded)
    {
      onReviewRequestVerificationSucceeded();
      onReviewRequestVerificationFailed = nil;
    }
	}
  else
  {
    if(onReviewRequestVerificationFailed)
      onReviewRequestVerificationFailed(nil);
    
    onReviewRequestVerificationFailed = nil;
  }
	
  
}

+ (void)connection:(NSURLConnection *)connection
  didFailWithError:(NSError *)error
{
  sDataFromConnection = nil;
  
  if(onReviewRequestVerificationFailed)
  {
    onReviewRequestVerificationFailed(nil);    
    onReviewRequestVerificationFailed = nil;
  }
}

#pragma mark - 修改过的验证方法，使用WMRequest.h

//-(void)verifyProductFromHanwenForReviewAccess:(NSString *)productId onComplete:(void (^)(NSNumber *))completionBlock onError:(void (^)(NSError *))errorBlock
//{
//    
//    if(REVIEW_ALLOWED)
//    {
//        onReviewRequestVerificationSucceeded = [completionBlock copy];
//        onReviewRequestVerificationFailed = [errorBlock copy];
//        self.theRequest = [WMRequest requestWithAPIID:@"20" andDelegate:self];
//        [self.theRequest startAsyncRequest];
//    }
//    else
//    {
//        completionBlock([NSNumber numberWithBool:NO]);
//    }
//}

-(void)verifyReceiptFromHanWenOnComplete:(void (^)(NSNumber*))completionBlock
                                 onError:(void (^)(NSError *))errorBlock
{
    //购买验证
    self.onReceiptVerificationSucceeded = completionBlock;
    self.onReceiptVerificationFailed = errorBlock;
    
    NSString* receipt_serial = [self encodeSerial:self.serialNum andRecipt:[self.receipt base64EncodedString]];
    WMUCTranscation* daoT = [[WMUCTranscation alloc] init];
    if(![daoT hasString:receipt_serial])
        [daoT insertWithDict:@{ @"serial_recipt" : receipt_serial }];
    //receipt_serial= receipt[0]+serial[0]+receipt[1]+serial[1]+receipt[2]+serial[2]+…
    //服务器交易校验
    if([CAQIUtility connectedToNetwork]){
        retryCount = 0;
        self.theRequestWM = [WMRequest requestWithAPIID:@"22" andDelegate:self];
        self.theRequestWM.tag = 22;
        [self.theRequestWM setPostValue:receipt_serial andParamName:@"receipt_serial"];
        [self.theRequestWM startAsyncRequest];
    }else{
        //NSError* error = [[NSError alloc] initWithDomain:@"hanwen" code:23 userInfo:@{@"error":@"网络连接失败, 正在重试"}];
        sleep(5);
        ;
        if(retryCount++ < 3)
            [self verifyReceiptFromHanWenOnComplete:completionBlock onError:errorBlock];
        else{
            WMUCTranscation* daoT = [[WMUCTranscation alloc] init];
            if(![daoT hasString:receipt_serial])
                [daoT insertWithDict:@{ @"serial_recipt" : receipt_serial }];
        }
    }
    

}
//-(void)getTranscationSerialNumOnComplete:(void (^)(NSString*))completionBlock
//                                 onError:(void (^)(NSError *))errorBlock
//{
//    //获取交易流水号
//    self.onGetSerialNumSucceeded = completionBlock;
//    self.onGetSerialNumFailed = errorBlock;
//    
//    self.theRequestWM = [WMRequest requestWithAPIID:@"21" andDelegate:self];
//    self.theRequestWM.tag = 21;
//    [self.theRequestWM startAsyncRequest];
//}
#pragma mark - WMRequest Delegate Methods
-(void)request:(WMRequest *)theRequest didFailed:(NSError *)theError
{
    NSError* error = [[NSError alloc] initWithDomain:@"hanwen" code:22 userInfo:@{@"error":@"验证失败"}];
    self.onReceiptVerificationFailed(error);
    self.onReceiptVerificationFailed = nil;
    
    
}
-(void)request:(WMRequest *)theRequest didLoadResultFromJsonString:(id)result
{
    if(theRequest.tag == 22){
        DLog(@"%@",result);
        if([result valueForKeyPath:@"data.userinfo.money"]){
            NSDictionary* d = [result valueForKeyPath:@"data.userinfo"];
            SJDaoUserData* daoU = [[SJDaoUserData alloc] init];
            NSString* where = [[NSString alloc] initWithFormat:@"rowid = %@", USERINFO_DEFAULT.shelfNo];
            [daoU updateWithDict:d where:where];
            if(self.onReceiptVerificationSucceeded)
            {
              self.onReceiptVerificationSucceeded([d valueForKey:@"money"]);
              self.onReceiptVerificationSucceeded = nil;
            }
        }else{
            NSError* error = [[NSError alloc] initWithDomain:@"hanwen" code:22 userInfo:@{@"error":@"验证失败"}];
            [self request:self.theRequestWM didFailed:error];
        }
        
    }
}
#pragma mark - Private
-(NSString*)encodeSerial:(NSString*)serial andRecipt:(NSString*)reciptStr
{
    //交叉编码流水号和base64 recipt
    if(reciptStr.length > serial.length){
        NSMutableString* tempStr = [[NSMutableString alloc] initWithCapacity: (serial.length + reciptStr.length) ];
        [reciptStr enumerateSubstringsInRange:NSMakeRange(0, [reciptStr length])
                                    options:NSStringEnumerationByComposedCharacterSequences | NSStringEnumerationLocalized
                                 usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop){
                                     [tempStr appendString:substring];
                                     if(substringRange.location < serial.length){
                                         NSString* sStr = [serial substringWithRange:substringRange];
                                         [tempStr appendString:sStr];
                                     }

                                 }];
        DLog(@"serial recipt length:%d", tempStr.length);
        return tempStr;
        
    }else{
        return @"";
    }
}
@end
