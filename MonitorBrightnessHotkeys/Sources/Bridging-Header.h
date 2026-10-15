// DDC declarations adapted from MonitorControl under the MIT License.
#pragma once

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

typedef CFTypeRef IOAVService;
extern IOAVService IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceWriteI2C(IOAVService service,
                                    uint32_t chipAddress,
                                    uint32_t dataAddress,
                                    void *inputBuffer,
                                    uint32_t inputBufferSize);
