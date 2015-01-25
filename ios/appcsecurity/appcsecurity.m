/**
 * This code is closed source and Confidential and Proprietary to
 * Appcelerator, Inc. All Rights Reserved.  This code MUST not be
 * modified, copy or otherwise redistributed without expression
 * written permission of Appcelerator. This file is licensed as
 * part of the Appcelerator Platform and governed under the terms
 * of the Appcelerator license agreement.
 */

#import "appcsecurity.h"

// by default, we use a relatively small number of rotations on the phone for the best speed
#define ITERATIONS 100

#define SALT_LENGTH 512
#define IV_LENGTH 32
#define HMAC_LENGTH 64
#define KEY_LENGTH kCCKeySizeAES256


/**
 * convert a buffer of char* to NSString* as hex
 */
static NSString* hexToString(unsigned char* data, size_t length) {
	NSMutableString* hash = [NSMutableString stringWithCapacity:length * 2];
	for (unsigned int i = 0; i < length; i++) {
		[hash appendFormat:@"%02x", data[i]];
	}
	return [hash lowercaseString];
}

/**
 * convert an NSData* to NSString* as hex
 */
static NSString* hexDataToString(NSData *_data) {
	NSUInteger length = [_data length];
	unsigned char *data = (unsigned char*)[_data bytes];
	NSMutableString* hash = [NSMutableString stringWithCapacity:length * 2];
	for (unsigned int i = 0; i < length; i++) {
		[hash appendFormat:@"%02x", data[i]];
	}
	return [hash lowercaseString];
}

/**
 * convert a NSString* as base64 back to hex
 */
static NSString* decodeB64AsHex(NSString *value) {
	NSData *data = [[NSData alloc] initWithBase64EncodedString:value options:NSDataBase64DecodingIgnoreUnknownCharacters];
	return hexDataToString(data);
}

/**
 * perform constant time comparision of two strings to prevent timing attack
 */
static BOOL constantTimeCompare(NSString *a, NSString *b) {
	int sentinel = 0;
	if (a.length != b.length) {
		return NO;
	}
	for (size_t c = 0; c <= (a.length - 1); c++) {
		sentinel |= [a characterAtIndex:c] ^ [b characterAtIndex:c];
	}
	return sentinel == 0;
}

/**
 * convert a hex NSString* to NSData*
 */
static NSData * dataFromHexString(NSString *originalHexString)
{
	NSString *hexString = [originalHexString stringByReplacingOccurrencesOfString:@"[ <>]" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, [originalHexString length])]; // strip out spaces (between every four bytes), "<" (at the start) and ">" (at the end)
	NSMutableData *data = [NSMutableData dataWithCapacity:[hexString length] / 2];
	for (NSInteger i = 0; i < [hexString length]; i += 2)
	{
		NSString *hexChar = [hexString substringWithRange: NSMakeRange(i, 2)];
		int value;
		sscanf([hexChar cStringUsingEncoding:NSASCIIStringEncoding], "%x", &value);
		uint8_t byte = value;
		[data appendBytes:&byte length:1];
	}

	return data;
}

/**
 * produce a PBKDF2 derived key from a key and saltAndPepper. returns hex value
 */
static NSString* pbkdf2 (NSString *key, NSString *saltAndPepper, size_t keyLength) {
	NSData *keyData = [key dataUsingEncoding:NSUTF8StringEncoding];
	const char *keyBytes = (const char*)[keyData bytes];
	NSData *saltPepperData = [saltAndPepper dataUsingEncoding:NSUTF8StringEncoding];
	uint8_t *saltPepperBytes = (uint8_t*)[saltPepperData bytes];

	uint8_t *result = malloc(sizeof(uint8_t)*keyLength);

	int status = CCKeyDerivationPBKDF(kCCPBKDF2, keyBytes, (size_t)keyData.length, saltPepperBytes, (size_t)saltAndPepper.length, kCCPRFHmacAlgSHA1, (uint)ITERATIONS, result, keyLength);

	if (status == kCCParamError) {
		free(result);
		return nil;
	}

	NSString *pk = hexToString(result,keyLength);

	free(result);

	return pk;
}

/**
 * decrypt using AES a string of encrypted data encoded as hex
 */
static NSData* aesDecrypt (NSString* keyHex, NSString *ivHex, NSString *encHex, float keyFactor) {
	NSData *key = dataFromHexString(keyHex);
	NSData *iv = dataFromHexString(ivHex);
	NSData *enc = dataFromHexString(encHex);

	size_t bufferSize = enc.length + kCCBlockSizeAES128;
	void *buffer = malloc (bufferSize);

	size_t numBytesDecrypted = 0;
	CCCryptorStatus cryptStatus = CCCrypt(kCCDecrypt,
										  kCCAlgorithmAES128,
										  kCCOptionPKCS7Padding,
										  key.bytes,
										  floor((float)(kCCKeySizeAES256 / keyFactor)),
										  iv.bytes,
										  enc.bytes,
										  enc.length,
										  buffer,
										  bufferSize,
										  &numBytesDecrypted );

	if (cryptStatus == kCCSuccess) {
		// The returned NSData takes ownership of the buffer and will free it on deallocation
		return [NSData dataWithBytesNoCopy:buffer length:numBytesDecrypted];
	}

	free(buffer);
	return nil;
}

/**
 * HMAC-256 data using key
 */
NSString* FNNAME(hmac256)(NSString *key, NSString *data)
{
	const char *cKey  = [key cStringUsingEncoding:NSASCIIStringEncoding];
	const char *cData = [data cStringUsingEncoding:NSASCIIStringEncoding];
	unsigned char cHMAC[CC_SHA256_DIGEST_LENGTH];
	CCHmac(kCCHmacAlgSHA256, cKey, strlen(cKey), cData, strlen(cData), cHMAC);
	NSData *result = [[NSData alloc] initWithBytes:cHMAC length:sizeof(cHMAC)];
	return hexDataToString(result);
}

/**
 * SHA1 a string
 */
NSString * FNNAME(sha1)(NSString *str) {
	NSData *data = [str dataUsingEncoding:NSUTF8StringEncoding];
	uint8_t digest[CC_SHA1_DIGEST_LENGTH];

	CC_SHA1(data.bytes, (CC_LONG)data.length, digest);

	NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];

	for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++)
	{
		[output appendFormat:@"%02x", digest[i]];
	}

	return [output lowercaseString];
}

/**
 * decrypt an encrypted value using computed derived key, pepper and hmacKey and return resulting plainText
 */
NSString* FNNAME(decryptWithKey)(NSString *value, NSString *derivedKeyHex, NSString *pepper, NSString *hmacKey, NSString *encoding, size_t size) {
	NSString *encryptedText = encoding && [encoding isEqualToString:@"base64"] ? decodeB64AsHex(value) : value;

	if ([encryptedText length] <= HMAC_LENGTH + SALT_LENGTH + IV_LENGTH) {
		return nil;
	}

	float keySizeFactor = (float)(256.0 / (float)size);
	NSString *hmacValue = [encryptedText substringWithRange:NSMakeRange(0, HMAC_LENGTH)];
	NSString *saltValue = [encryptedText substringWithRange:NSMakeRange(HMAC_LENGTH, SALT_LENGTH)];
	NSString *ivValue = [encryptedText substringWithRange:NSMakeRange(HMAC_LENGTH + SALT_LENGTH, IV_LENGTH)];
	NSString *encValue = [encryptedText substringFromIndex:HMAC_LENGTH + SALT_LENGTH + IV_LENGTH];
	NSString *saltAndPepper = FNNAME(sha1)([NSString stringWithFormat:@"%@%@",saltValue,pepper]);

	NSString *hmacTestStr = [NSString stringWithFormat:@"%@%@%@",encValue,saltAndPepper,ivValue];
	NSString *hmacTestValue = FNNAME(hmac256)(hmacKey, hmacTestStr);

#if APPC_SECURITY_DEBUG && !TARGET_OS_IPHONE && TARGET_IPHONE_SIMULATOR
	NSLog(@"encryptedText = %@",encryptedText);
	NSLog(@"hmac = %@",hmacValue);
	NSLog(@"saltValue = %@",saltValue);
	NSLog(@"ivValue = %@",ivValue);
	NSLog(@"encValue = %@",encValue);
	NSLog(@"saltAndPepper = %@",saltAndPepper);
	NSLog(@"hmacTest = %@",hmacTestStr);
	NSLog(@"hmacTestValue = %@",hmacTestValue);
#endif

	if (constantTimeCompare(hmacTestValue, hmacValue)==NO) {
		return nil;
	}

	NSData *result = aesDecrypt(derivedKeyHex, ivValue, encValue, keySizeFactor);
	return [[NSString alloc] initWithData:result encoding:NSUTF8StringEncoding];
}

/**
 * decrypt an encrypted value using key, pepper and hmacKey and return resulting plainText
 */
NSString* FNNAME(decrypt)(NSString *value, NSString *key, NSString *pepper, NSString *hmacKey, NSString *encoding, size_t size) {

	NSString *encryptedText = encoding && [encoding isEqualToString:@"base64"] ? decodeB64AsHex(value) : value;

	if ([encryptedText length] <= HMAC_LENGTH + SALT_LENGTH + IV_LENGTH) {
		return nil;
	}

	float keySizeFactor = (float)(256.0 / (float)size);
	NSString *hmacValue = [encryptedText substringWithRange:NSMakeRange(0, HMAC_LENGTH)];
	NSString *saltValue = [encryptedText substringWithRange:NSMakeRange(HMAC_LENGTH, SALT_LENGTH)];
	NSString *ivValue = [encryptedText substringWithRange:NSMakeRange(HMAC_LENGTH + SALT_LENGTH, IV_LENGTH)];
	NSString *encValue = [encryptedText substringFromIndex:HMAC_LENGTH + SALT_LENGTH + IV_LENGTH];
	NSString *saltAndPepper = FNNAME(sha1)([NSString stringWithFormat:@"%@%@",saltValue,pepper]);

	NSString *hmacTestStr = [NSString stringWithFormat:@"%@%@%@",encValue,saltAndPepper,ivValue];
	NSString *hmacTestValue = FNNAME(hmac256)(hmacKey, hmacTestStr);

#if APPC_SECURITY_DEBUG && !TARGET_OS_IPHONE && TARGET_IPHONE_SIMULATOR
	NSLog(@"encryptedText = %@",encryptedText);
	NSLog(@"hmac = %@",hmacValue);
	NSLog(@"saltValue = %@",saltValue);
	NSLog(@"ivValue = %@",ivValue);
	NSLog(@"encValue = %@",encValue);
	NSLog(@"saltAndPepper = %@",saltAndPepper);
	NSLog(@"hmacTest = %@",hmacTestStr);
	NSLog(@"hmacTestValue = %@",hmacTestValue);
#endif

	if (constantTimeCompare(hmacTestValue, hmacValue)==NO) {
		return nil;
	}

	NSString *derivedKey = pbkdf2(key, saltAndPepper,floor((float)(KEY_LENGTH/keySizeFactor)));
	NSData *result = aesDecrypt(derivedKey, ivValue, encValue, keySizeFactor);
	return [[NSString alloc] initWithData:result encoding:NSUTF8StringEncoding];
}
