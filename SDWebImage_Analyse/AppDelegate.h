//
//  AppDelegate.h
//  SDWebImage_Analyse
//
//  Created by wushangkun on 16/5/4.
//  Copyright © 2016年 wushangkun. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>

@property (strong, nonatomic) UIWindow *window;

@property (strong, nonatomic) UINavigationController *navigationController;

@end

/*

 SDWebImage开源第三方库:
 
 提供UIImageView的一个分类，以支持网络图片的加载与缓存管理
 
 一个异步的图片加载器
 
 一个异步的内存+磁盘图片缓存，并具有自动缓存过期处理功能
 
 支持GIF图片
 
 支持WebP图片
 
 后台图片解压缩处理
 
 确保同一个URL的图片不被下载多次
 
 确保虚假的URL不会被反复加载
 
 确保下载及缓存时，主线程不被阻塞
 
 优良的性能
 
 使用GCD和ARC
 
 支持Arm64
 

 */