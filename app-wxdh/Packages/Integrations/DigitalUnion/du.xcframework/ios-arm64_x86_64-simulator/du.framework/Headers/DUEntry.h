#import <Foundation/Foundation.h>
#define DU_LABEL_CUSTOM 0
#define DU_LABEL_UNIVERSAL 1
#define DU_LABEL_DEVICE 2
static NSString *SDKVer = @"3.8.3";

@interface DUEntry : NSObject
typedef void (^getSecVerificationBlock)(NSString *cdidStr);
typedef void (^DUBlock)(NSString *resultStr);
@property (atomic, copy) getSecVerificationBlock getSecVerificationBlock DEPRECATED_MSG_ATTRIBUTE("请使用 - (void)getQueryID:(NSString *)strMsg dublock:(DUQueryBlock)block");

/**
 获取数盟生成的IDFA
 @param block 回调block
 */
- (void)getAdsID:(DUBlock)block;

/**
 设置自定义消息，以键值对形式存储，可多次调用
 @param msgKey 自定义消息key值
 @param msgValue 自定义消息value值
 */
- (void)setMessage:(NSString *)msgKey msgValue:(NSString *)msgValue;

/**
 设置渠道
 @param strChannel 渠道类型
 */
- (void)setChannel:(NSString *)strChannel;

/**
 设置客户CID 仅需设置一次
 @param strCustomerId 数盟分配的客户CID
 */
- (void)setCustomerId:(NSString *)strCustomerId;

/**
 设置存量标识
 @param bExisting 是否为存量设备
 */
- (void)setExisting:(BOOL)bExisting DEPRECATED_MSG_ATTRIBUTE("请使用 - (void)setConfig:(NSString *)key value:(NSString *)value");

/**
 设置自定义域名
 @param strDomainName 转发客户配置的自定义域名
 */
- (void)setDomainName:(NSString *)strDomainName DEPRECATED_MSG_ATTRIBUTE("请使用 - (void)setConfig:(NSString *)key value:(NSString *)value");

/**
 信息采集上报方法
 */
- (void)run DEPRECATED_MSG_ATTRIBUTE("请使用 - (void)getQueryID:(NSString *)strMsg dublock:(DUQueryBlock)block");

/**
 旧的同步获取ID方法 后面会弃用
 */
- (NSString *)getDUSecVerification DEPRECATED_MSG_ATTRIBUTE("请使用 - (NSString *)getQueryID:(NSString *)strMsg");

/**
 单例方法
 */
+ (instancetype)sharedInstance;

/**
 审计业务
 @param block 回调block
 @param eventCode  业务编码
 @param eventCode  自定义消息 可选
 */
- (void)onEvent:(DUBlock)block eventCode:(NSString *)eventCode optMsg:(NSString *)optMsg;

/**
获取风险感知标签
@param labelType  标签类型，目前仅支持 DU_LABEL_UNIVERSAL
@param block  回调函数
 */
- (void)getDeviceLabel:(DUBlock)block labelType:(NSInteger)labelType;

/**
同步获取数盟ID方法
@param strMsg  自定义消息 可选
 */
- (NSString *)getQueryID:(NSString *)strMsg;

/**
异步获取数盟ID方法
@param strMsg  自定义消息 可选
@param dublock  回调block
 */
- (void)getQueryID:(NSString *)strMsg dublock:(DUBlock)block;

/**
 获取网络编码
 @param block 回调block
 */
- (void)getNetCode:(DUBlock)block;

/**
 用于分析问题
 */
- (NSString *)getTraceInfo;

/**
 配置方法
 @param key  配置信息的key值
 @param value  配置信息的key值
 具体可用key 值与对应value值设置请查看集成文档
 */
- (void)setConfig:(NSString *)key value:(NSString *)value;

/**
 推送接口 仅上报无回调
 @param msg 本次上报的自定义消息
 */
- (void)optReport:(NSString *)msg;
@end
