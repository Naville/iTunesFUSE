#import "iTunesFuse.h"
#import "NSError+POSIX.h"
#import <OSXFUSE/OSXFUSE.h>
#include <stdio.h>
#import <sys/stat.h>
#import <sys/vnode.h>
#import <sys/xattr.h>
#ifdef DEBUG
#define DLog(fmt, ...)                                                         \
  NSLog((@"%s [Line %d] " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__)
#else
#define DLog(...)
#endif

#define ProcessPath(path)                                                      \
  if (self->isStorageMounted) {                                                \
    path = [self->strPath stringByAppendingPathComponent:path];            \
  } else {                                                                     \
    path = [self->caPath stringByAppendingPathComponent:path];              \
  }

#define FileInCache(path)                                                      \
  [[NSFileManager defaultManager]                                              \
      fileExistsAtPath:[self->caPath stringByAppendingPathComponent:path]]

#define GetStorageFromAccessPath(path) [self->strPath stringByAppendingPathComponent:[path stringByReplacingOccurrencesOfString:MOUNT_POINT withString:@""]]
#define GetCachePathFromStoragePath(path) [self->caPath stringByAppendingPathComponent:[path stringByReplacingOccurrencesOfString:self->strPath withString:@""]]
#define GetCachePathFromAccessPath(path) [self->caPath stringByAppendingPathComponent:[path stringByReplacingOccurrencesOfString:MOUNT_POINT withString:@""]]
@implementation iTunesFuse {
  NSString* caPath;//CachePath
  NSString* strPath;//StoragePath
  BOOL isStorageMounted;
}
+ (void)load {
  static GMUserFileSystem *fs_ = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    fs_ = [[GMUserFileSystem alloc] initWithDelegate:[iTunesFuse shared]
                                        isThreadSafe:NO];
    NSMutableArray *options = [NSMutableArray array];
    //[options addObject:@"rdonly"];
    [options addObject:@"volname=iTunesFuse"];
    [options addObject:@"native_xattr"];
    [options
        addObject:
            @"volicon=/Applications/iTunes.app/Contents/Resources/iTunes.icns"];
    [fs_ mountAtPath:MOUNT_POINT withOptions:options];
    NSLog(@"Mounted:%@", fs_);
  });
}
+ (id)shared {
  static iTunesFuse *shared = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    shared = [[iTunesFuse alloc] init];
  });
  return shared;
}
- (void)didMount:(NSNotification *)notification {
}

- (void)didUnmount:(NSNotification *)notification {
}
- (void)handleDrive:(NSNotification *)notification {
  BOOL isDirectory = NO;
  if ([[NSFileManager defaultManager] fileExistsAtPath:self->strPath
                                           isDirectory:&isDirectory] &&
      isDirectory) {
    DLog(@"iTunesFUSE Storage Device Mounted");
    self->isStorageMounted = YES;
  } else {
    DLog(@"iTunesFUSE Storage Device UnMounted");
    self->isStorageMounted = NO;
  }
}
- (instancetype)init {
  self = [super init];
  // Register Notification
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(didMount:)
                                               name:kGMUserFileSystemDidMount
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(didUnmount:)
                                               name:kGMUserFileSystemDidUnmount
                                             object:nil];
  [[[NSWorkspace sharedWorkspace] notificationCenter]
      addObserver:self
         selector:@selector(handleDrive:)
             name:NSWorkspaceDidMountNotification
           object:nil];
  [[[NSWorkspace sharedWorkspace] notificationCenter]
      addObserver:self
         selector:@selector(handleDrive:)
             name:NSWorkspaceDidUnmountNotification
           object:nil];
  // Prepare IVARs
  self->caPath =
      [NSHomeDirectory() stringByAppendingPathComponent:@"iTunesFuseCache"];
  self->strPath=StoragePath;
  [[NSFileManager defaultManager] createDirectoryAtPath:self->caPath
                            withIntermediateDirectories:NO
                                             attributes:nil
                                                  error:nil];
  [self handleDrive:nil];
  return self;
}
- (NSString *)description {
  return [NSString stringWithFormat:@"iTunesFUSE Cache:%@ Storage:%@",
                                    self->caPath, self->strPath];
}
// Actual Implementations
- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path
                                 error:(NSError **)error {
  ProcessPath(path);
  DLog(@"%@", path);
  return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path
                                                             error:error];
}
- (NSDictionary *)attributesOfItemAtPath:(NSString *)path
                                userData:(id)userData
                                   error:(NSError **)error {
  ProcessPath(path);
  DLog(@"%@", path);
  return
      [[NSFileManager defaultManager] attributesOfItemAtPath:path error:error];
}
- (NSDictionary *)attributesOfFileSystemForPath:(NSString *)path
                                          error:(NSError **)error {
  ProcessPath(path);
  DLog(@"%@", path);
  return [[NSFileManager defaultManager] attributesOfFileSystemForPath:path
                                                                 error:error];
}
- (BOOL)setAttributes:(NSDictionary *)attributes
         ofItemAtPath:(NSString *)path
             userData:(id)userData
                error:(NSError **)error {
  ProcessPath(path);
  DLog(@"%@", path);
  NSNumber *offset = [attributes objectForKey:NSFileSize];
  if (offset) {
    int ret = truncate([path UTF8String], [offset longLongValue]);
    if (ret < 0) {
      if (error) {
        *error = [NSError errorWithPOSIXCode:errno];
      }
      return NO;
    }
  }
  NSNumber *flags = [attributes objectForKey:kGMUserFileSystemFileFlagsKey];
  if (flags != nil) {
    int rc = chflags([path UTF8String], [flags intValue]);
    if (rc < 0) {
      if (error) {
        *error = [NSError errorWithPOSIXCode:errno];
      }
      return NO;
    }
  }
  return [[NSFileManager defaultManager] setAttributes:attributes
                                          ofItemAtPath:path
                                                 error:error];
}
- (NSData *)contentsAtPath:(NSString *)path {
#warning Implement Compression
  if (FileInCache(path) && !self->isStorageMounted) {
    // Unmounted.Fix path to cache
    path = GetCachePathFromAccessPath(path);
  } else if (!FileInCache(path) && self->isStorageMounted) {
    // Mounted.Not In Cache. Save and return self->strPath so we have loseless
    // version
    dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      NSString* ContainingCacheFolder=[GetCachePathFromAccessPath(path) stringByDeletingLastPathComponent];
      NSLog(@"ContainingCacheFolder:%@",ContainingCacheFolder);
      [[NSFileManager defaultManager]
                createDirectoryAtPath:
                    ContainingCacheFolder
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];
      [[NSFileManager defaultManager] copyItemAtPath:GetStorageFromAccessPath(path)
                                              toPath:[ContainingCacheFolder stringByAppendingPathComponent:path.lastPathComponent]
                                               error:nil];
    DLog(@"Caching %@ to %@", GetStorageFromAccessPath(path), [ContainingCacheFolder stringByAppendingPathComponent:path.lastPathComponent]);
});
    return [[NSFileManager defaultManager] contentsAtPath:GetStorageFromAccessPath(path)];//Return original version first. Do cache in background
  } else if (FileInCache(path) && self->isStorageMounted) {
    // Mounted.File already cached.Just fix path
    path = GetStorageFromAccessPath(path);
  } else {
    return nil;
  }
  return [[NSFileManager defaultManager] contentsAtPath:path];
}
- (BOOL)openFileAtPath:(NSString *)path
                  mode:(int)mode
              userData:(id *)userData
                 error:(NSError **)error {
  ProcessPath(path);
  DLog(@"%@", path);
  int fd = open(path.UTF8String, mode);
  *userData = [NSNumber numberWithInt:fd];
  if (fd == -1) {
    *error = [NSError errorWithPOSIXCode:errno];
    return NO;
  }
  return YES;
}
- (void)releaseFileAtPath:(NSString *)path userData:(id)userData {
  if (userData != nil) {
    ProcessPath(path);
    DLog(@"%@", path);
    close([(NSNumber *)userData intValue]);
  }
}
- (int)readFileAtPath:(NSString *)path
             userData:(id)userData
               buffer:(char *)buffer
                 size:(size_t)size
               offset:(off_t)offset
                error:(NSError **)error {
  DLog(@"%@", path);
  NSNumber *num = (NSNumber *)userData;
  int fd = [num longValue];
  int ret = pread(fd, buffer, size, offset);
  if (ret < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return -1;
  }
  return ret;
}
- (int)writeFileAtPath:(NSString *)path
              userData:(id)userData
                buffer:(const char *)buffer
                  size:(size_t)size
                offset:(off_t)offset
                 error:(NSError **)error {
  DLog(@"%@", path);
  NSNumber *num = (NSNumber *)userData;
  int fd = [num longValue];
  int ret = pwrite(fd, buffer, size, offset);
  if (ret < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return -1;
  }
  return ret;
}
- (BOOL)preallocateFileAtPath:(NSString *)path
                     userData:(id)userData
                      options:(int)options
                       offset:(off_t)offset
                       length:(off_t)length
                        error:(NSError **)error {
  DLog(@"%@", path);
  NSNumber *num = (NSNumber *)userData;
  int fd = [num longValue];

  fstore_t fstore;

  fstore.fst_flags = 0;
  if (options & ALLOCATECONTIG) {
    fstore.fst_flags |= F_ALLOCATECONTIG;
  }
  if (options & ALLOCATEALL) {
    fstore.fst_flags |= F_ALLOCATEALL;
  }

  if (options & ALLOCATEFROMPEOF) {
    fstore.fst_posmode = F_PEOFPOSMODE;
  } else if (options & ALLOCATEFROMVOL) {
    fstore.fst_posmode = F_VOLPOSMODE;
  }

  fstore.fst_offset = offset;
  fstore.fst_length = length;

  if (fcntl(fd, F_PREALLOCATE, &fstore) == -1) {
    *error = [NSError errorWithPOSIXCode:errno];
    return NO;
  }
  return YES;
}
- (BOOL)exchangeDataOfItemAtPath:(NSString *)path1
                  withItemAtPath:(NSString *)path2
                           error:(NSError **)error {
  ProcessPath(path1);
  ProcessPath(path2);
  DLog(@"Path1:%@ Path2:%@", path1, path2);
  int ret = exchangedata([path1 UTF8String], [path2 UTF8String], 0);
  if (ret < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return NO;
  }
  return YES;
}
- (NSArray *)extendedAttributesOfItemAtPath:(NSString *)path
                                      error:(NSError **)error {
  ProcessPath(path);
  DLog(@"%@", path);

  ssize_t size = listxattr([path UTF8String], nil, 0, XATTR_NOFOLLOW);
  if (size < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return nil;
  }
  NSMutableData *data = [NSMutableData dataWithLength:size];
  size = listxattr([path UTF8String], (char *)[data mutableBytes],
                   [data length], XATTR_NOFOLLOW);
  if (size < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return nil;
  }
  NSMutableArray *contents = [NSMutableArray array];
  char *ptr = (char *)[data bytes];
  while (ptr < ((char *)[data bytes] + size)) {
    NSString *s = [NSString stringWithUTF8String:ptr];
    [contents addObject:s];
    ptr += ([s length] + 1);
  }
  return contents;
}

- (NSData *)valueOfExtendedAttribute:(NSString *)name
                        ofItemAtPath:(NSString *)path
                            position:(off_t)position
                               error:(NSError **)error {
  ProcessPath(path);
  DLog(@"%@", path);

  ssize_t size = getxattr([path UTF8String], [name UTF8String], nil, 0,
                          position, XATTR_NOFOLLOW);
  if (size < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return nil;
  }
  NSMutableData *data = [NSMutableData dataWithLength:size];
  size = getxattr([path UTF8String], [name UTF8String], [data mutableBytes],
                  [data length], position, XATTR_NOFOLLOW);
  if (size < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return nil;
  }
  return data;
}

- (BOOL)setExtendedAttribute:(NSString *)name
                ofItemAtPath:(NSString *)path
                       value:(NSData *)value
                    position:(off_t)position
                     options:(int)options
                       error:(NSError **)error {
  // Setting com.apple.FinderInfo happens in the kernel, so security related
  // bits are set in the options. We need to explicitly remove them or the call
  // to setxattr will fail.
  // TODO: Why is this necessary?
  ProcessPath(path);
  DLog(@"%@", path);
  options &= ~(XATTR_NOSECURITY | XATTR_NODEFAULT);

  int ret = setxattr([path UTF8String], [name UTF8String], [value bytes],
                     [value length], position, options | XATTR_NOFOLLOW);
  if (ret < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return NO;
  }
  return YES;
}

- (BOOL)removeExtendedAttribute:(NSString *)name
                   ofItemAtPath:(NSString *)path
                          error:(NSError **)error {
  ProcessPath(path);
  DLog(@"%@", path);

  int ret = removexattr([path UTF8String], [name UTF8String], XATTR_NOFOLLOW);
  if (ret < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return NO;
  }
  return YES;
}
- (BOOL)moveItemAtPath:(NSString *)source
                toPath:(NSString *)destination
                 error:(NSError **)error {
  // We use rename directly here since NSFileManager can sometimes fail to
  // rename and return non-posix error codes.
  ProcessPath(source);
  ProcessPath(destination);
  DLog(@"%@ %@", source, destination);
  int ret = rename([source UTF8String], [destination UTF8String]);
  if (ret < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return NO;
  }
  return YES;
}

#pragma mark Removing an Item

- (BOOL)removeDirectoryAtPath:(NSString *)path error:(NSError **)error {
  // We need to special-case directories here and use the bsd API since
  // NSFileManager will happily do a recursive remove :-(
  ProcessPath(path);
  int ret = rmdir([path UTF8String]);
  if (ret < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return NO;
  }
  return YES;
}

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error {
  // NOTE: If removeDirectoryAtPath is commented out, then this may be called
  // with a directory, in which case NSFileManager will recursively remove all
  // subdirectories. So be careful!
  ProcessPath(path);
  return [[NSFileManager defaultManager] removeItemAtPath:path error:error];
}

#pragma mark Creating an Item

- (BOOL)createDirectoryAtPath:(NSString *)path
                   attributes:(NSDictionary *)attributes
                        error:(NSError **)error {

  ProcessPath(path);
  return [[NSFileManager defaultManager] createDirectoryAtPath:path
                                   withIntermediateDirectories:NO
                                                    attributes:attributes
                                                         error:error];
}

- (BOOL)createFileAtPath:(NSString *)path
              attributes:(NSDictionary *)attributes
                   flags:(int)flags
                userData:(id *)userData
                   error:(NSError **)error {

  ProcessPath(path);
  mode_t mode = [[attributes objectForKey:NSFilePosixPermissions] longValue];
  int fd = open([path UTF8String], flags, mode);
  if (fd < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return NO;
  }
  *userData = [NSNumber numberWithLong:fd];
  return YES;
}

- (BOOL)createFileAtPath:(NSString *)path
              attributes:(NSDictionary *)attributes
                userData:(id *)userData
                   error:(NSError **)error {
  return [self createFileAtPath:path
                     attributes:attributes
                          flags:(O_RDWR | O_CREAT | O_EXCL)
                       userData:userData
                          error:error];
}

#pragma mark Linking an Item

- (BOOL)linkItemAtPath:(NSString *)source
                toPath:(NSString *)destination
                 error:(NSError **)error {
  ProcessPath(source);
  ProcessPath(destination);
  // We use link rather than the NSFileManager equivalent because it will copy
  // the file rather than hard link if part of the root path is a symlink.
  int rc = link([source UTF8String], [destination UTF8String]);
  if (rc < 0) {
    if (error) {
      *error = [NSError errorWithPOSIXCode:errno];
    }
    return NO;
  }
  return YES;
}

#pragma mark Symbolic Links

- (BOOL)createSymbolicLinkAtPath:(NSString *)path
             withDestinationPath:(NSString *)otherPath
                           error:(NSError **)error {
  ProcessPath(path);
  return [[NSFileManager defaultManager] createSymbolicLinkAtPath:path
                                              withDestinationPath:otherPath
                                                            error:error];
}

- (NSString *)destinationOfSymbolicLinkAtPath:(NSString *)path
                                        error:(NSError **)error {
  ProcessPath(path);
  return [[NSFileManager defaultManager] destinationOfSymbolicLinkAtPath:path
                                                                   error:error];
}
@end

int main() {
  [[NSRunLoop currentRunLoop] run];
  return 0;
}
