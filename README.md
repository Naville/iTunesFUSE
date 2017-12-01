# iTunesFUSE
This iTunes plugin aims to provide an abstraction layer for iTunes users which have a large iTunes Library that is stored on some kind of external storage device, referred to as ``StoragePath``.
This is built on top of the official demo LoopBackFS
## Design
- By design iTunesFUSE mounts itself at ``/Volumes/iTunesFUSE``(known as ``MountPoint`` ) with the cached content stored at ``~/iTunesFuseCache/``(known as ``CachePath`` ) with the exact folder structure as ``StoragePath``  
- iTunesFUSE also supports "Stashing" that cached file creation and sync with ``StoragePath`` later on.

### On Storage Mount    

- Switch to mapping mode where ``MountPoint`` is mapped directly to *StoragePath*
- Push Stashing Content To ``StoragePath``
- ``Read from``/``Write to`` ``StoragePath``, cache an optimized version of the media in ``CachePath``where feasible

### On Storage Unmount
- Switch to caching mode where ``MountPoint`` is a mapping of ``CachePath``
- Stash new file creation in stashing folder without optimizing

## Building
  Use cmake
  ``cmake -DStoragePath=@\"YOU_STORAGE_PATH\" -DMOUNT_POINT=@\"DEFAULT_MOUNT_POINT\" PATH_TO_PROJECT_SOURCE``
