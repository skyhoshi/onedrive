# Changelog
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 2.5.6 - 2025-06-05

### Added
*   Enhancement: Add gdc support to enable Gentoo compilation
*   Enhancement: Add a notification to user regarding number of objects received from OneDrive API
*   Enhancement: Update 'skip_file' documentation and option validation
*   Enhancement: Add a new configuration option 'force_session_upload' to support editors and applications using atomic save operations
*   Enhancement: Added 2 functions to check for the presence of required remoteItem elements to create a Shared Folder DB entries
*   Implement Feature Request: Add local recycle bin or trash folder option
*   Implement Feature Request: Add configurable upload delay to support Obsidian
*   Implement Feature Request: Add validation of bools in config file 
*   Implement Feature Request: Add native support for authentication via Intune dbus interface 
*   Implement Feature Request: Implement OAuth2 Device Authorisation Flow 

### Changed
*   Change logging output level for JSON elements that contain URL encoding
*   Change 'configure.ac' to use a static date value as Debian 'reproducible' build process forces a future date to rebuild any code to determine reproducibility

### Fixed
*   Fix Regression: Fixed regression in handling Microsoft OneNote package folders being created in error 
*   Fix Regression: Fix OneNote file MimeType detection
*   Fix Regression: Fix supporting Personal Shared Folders that have been renamed
*   Fix Bug: Correct the logging output for 'skip_file' exclusions 
*   Fix Bug: Validate raw JSON from Graph API for 15 character driveId API bug
*   Fix Bug: Fix JSON exception on webhook subscription renewal due to 308 redirect
*   Fix Bug: Update 'sync_list' line parsing to correctly escape characters for regex parsing
*   Fix Bug: Fix that an empty folder or folder with Microsoft OneNote files are deleted online when content is shared from a SharePoint Library Document Root
*   Fix Bug: Fix that empty 'skip_file' forces resync indefinitely
*   Fix Bug: Fix that 'sync_list' rule segment|depth check fails in some scenarios and implement a better applicable mechanism check
*   Fix Bug: Resolve crash when getpwuid() breaks when there is a glibc version mismatch
*   Fix Bug: Resolve crash when opening file fails when computing file hash
*   Fix Bug: Add check for invalid exclusion 'sync_list' exclusion rules
*   Fix Bug: Fix uploading of modified files when using --upload-only & --remove-source-files
*   Fix Bug: Fix local path calculation for Relocated OneDrive Business Shared Folders 
*   Fix Bug: Fix 'sync_list' anywhere rule online directory creation
*   Fix Bug: Fix online path creation to ensure parental path structure is created in a consistent manner
*   Fix Bug: Fix handling of POSIX check for existing online items
*   Fix Bug: Fix args printing in dockerfile entrypoint
*   Fix Bug: Fix the testing of parental structure for 'sync_list' inclusion when adding inotify watches
*   Fix Bug: Fix failure to handle API 403 response when file fragment upload fails
*   Fix Bug: Fix application notification output to be consistent when skipping integrity checks
*   Fix Bug: Fix how local timestamps are modified 
*   Fix Bug: Fix how online remaining free space is calculated and consumed internally for free space tracking
*   Fix Bug: Fix logic of determining if a file has valid integrity when using --disable-upload-validation
*   Fix Bug: Format the OneDrive change into a consumable object for the database earlier to use values in application logging
*   Fix Bug: Fix upload session offset handling to prevent desynchronisation on large files
*   Fix Bug: Fix implementation of 'write_xattr_data' to support FreeBSD
*   Fix Bug: Update hash functions to ensure file is closed if opened 
*   Fix Bug: Dont blindly run safeBackup() if the online timestamp is newer 
*   Fix Bug: Only set xattr values when not using --dry-run 
*   Fix Bug: Fix UTC conversion for existing file timestamp post file download
*   Fix Bug: Fix that 'check_nosync' and 'skip_size' configuration options when changed, were not triggering a --resync correctly
*   Fix Bug: Ensure file is closed before renaming to improve compatibility with GCS buckets and network filesystems 
*   Fix Bug: If a file fails to download, path fails to exist. Check path existence before setting xattr values

### Updated
*   Updated .gitignore to ignore files created during configure to be consistent with other files generated from .in templates
*   Updated bash,fish and zsh completion files to align with application options
*   Updated 'config' file to align to application options with applicable descriptions
*   Updated testbuild runner
*   Updated Fedora Docker OS version to Fedora 42
*   Updated Ubuntu 24.10 curl version 8.9.1 to known bad curl versions and document the bugs associated with it
*   Updated Makefile to pass libraries after source files in compiler invocation
*   Updated 'configure.ac' to support more basename formats for DC
*   Update how threads are set based on available CPUs 
*   Update setLocalPathTimestamp logging output 
*   Update when to perform thread check and set as early as possible 
*   Updated documentation

## 2.5.5 - 2025-03-17

### Added
*   Implement Feature Request: Implement 'transfer_order' configuration option to allow the user to determine what order files are transferred in
*   Implement Feature Request: Implement 'disable_permission_set' configuration option to not set directory and file permissions
*   Implement Feature Request: Implement 'write_xattr_data' configuration option to add information about file creator/last editor as extended file attributes
*   Enhancement: Add support for --share-password option when --create-share-link is called
*   Enhancement: Add support 'localizedMessage' error messages in application output if this is provided in the JSON response from Microsoft Graph API

### Changed
*   Changed curl debug logging to --debug-https as this is more relevant
*   Comprehensively overhauled how OneDrive Personal Shared Folders are handled due to major OneDrive API backend platform user migration and major differences in API response output
*   Comprehensively changed OneDrive Personal 'driveId' value checking due to major OneDrive API backend platform user migration and major differences in API response output

### Fixed
*   Fix Bug: Fix path calculation for Client Side Filtering evaluations for Personal Accounts
*   Fix Bug: Fix path calculation for Client Side Filtering evaluations for Business Accounts
*   Fix Bug: Only perform path calculation if this is actually required
*   Fix Bug: Fix check for 'globbing' and 'wildcard' rules, that the number of segments before the first wildcard character need to match before the actual rule can be applied
*   Fix Bug: When using 'sync_list' , ignore specific exclusion to scan that path for new data, which may be actually included by an include rule, but the parent path is excluded
*   Fix Bug: When removing a OneDrive Personal Shared Folder, remove the actual link, not the remote user folder
*   Fix Bug: Fix 'Unsupported platform' for inotify watches by using the correct predefined version definition for Linux.

### Updated
*   Updated Fedora Docker OS version to Fedora 41
*   Updated Alpine Docker OS version to Alpine 3.21
*   Updated documentation

## 2.5.4 - 2025-02-03

### Added
*   Implement Feature Request: Support Permanent Delete on OneDrive
*   Implement Feature Request: Support the moving of Shared Folder Links to other folders (Business Accounts only)
*   Enhancement: Added due to ongoing Ubuntu issues with 'curl' and 'libcurl', updated the documentation to include all relevant curl bugs and affected versions
*   Enhancement: Added quota status messages for nearing | critical | exceeded based on OneDrive Account API response
*   Enhancement: Added Docker variable to implement a sync once option
*   Enhancement: Added configuration option 'create_new_file_version' to force create new versions if that is the desire
*   Enhancement: Added support for adding SharePoint Libraries as Shared Folder Links
*   Enhancement: Added code and documentation changes to support FreeBSD
*   Enhancement: Added a check for the 'sea8cc6beffdb43d7976fbc7da445c639' string in the Microsoft OneDrive Personal Account Root ID response that denotes that the account cannot access Microsoft OneDrive at this point in time
*   Enhancement: Added './' sync_list rule check as this does not align to the documentation and these rules will not get matched correctly.

### Changed
*   Changed how debug logging outputs HTTP response headers and when this occurs
*   Changed when the check for no --sync | --monitor occurs so that this fails faster to avoid setting up all the other components
*   Changed isValidUTF8 function to use 'validate' rather than individual character checking and enhance checks including length constraints
*   Changed --dry-run authentication message to remove ambiguity that --dry-run cannot be used to authenticate the application

### Fixed
*   Fix Regression: Fixed regression that sync_list does not traverse shared directories
*   Fix Regression: Fixed regression of --display-config use after fast failing if --sync or --monitor has not been used
*   Fix Regression: Fixed regression from v2.4.x in handling uploading new and modified content to OneDrive Business and SharePoint to not create new versions of files post upload which adds to user quota
*   Fix Regression: Add back file transfer metrics which was available in v2.4.x
*   Fix Regression: Add code to support using 'display_processing_time' for functional performance which was available in v2.4.x
*   Fix Bug: Fixed build issue for OpenBSD (however support for OpenBSD itself is still a work-in-progress)
*   Fix Bug: Fixed issue regarding parsing OpenSSL and when unable to be parsed, do not force the application to exit
*   Fix Bug: Fixed the import of 'sync_list' rules due to OneDriveGUI creating a blank empty file by default
*   Fix Bug: Fixed the display of 'sync_list' rules due to OneDriveGUI creating a blank empty file by default
*   Fix Bug: Fixed that Business Shared Items shortcuts are skipped as being incorrectly detected as Microsoft OneNote Notebook items
*   Fix Bug: Fixed space calculations due to using ulong variable type to ensure that if calculation is negative, value is negative
*   Fix Bug: Fixed issue when downloading a file, and this fails due to an API error (400, 401, 5xx), online file is then not deleted
*   Fix Bug: Fixed skip_dir logic when reverse traversing folder structure
*   Fix Bug: Fixed issue that when using 'sync_list' if a file is moved to a newly created online folder, whilst the folder is created database wise, ensure this folder exists on local disk
*   Fix Bug: Fixed path got deleted in handling of move & close_write event when using 'vim'.
*   Fix Bug: Fixed that the root Personal Shared Folder is not handled due to missing API data European Data Centres
*   Fix Bug: Fixed the the local timestamp is not set when using --disable-download-validation
*   Fix Bug: Fixed Upload|Download Loop for AIP Protected File in Monitor Mode
*   Fix Bug: Fixed --single-directory Shared Folder DB entry creation
*   Fix Bug: Fixed API Bug to ensure that OneDrive Personal Drive ID and Remote Drive ID values are 16 characters, padded by leading zeros if the provided JSON data has dropped these leading zeros
*   Fix Bug: Fixed testInternetReachability function so that this always returns a boolean value and not throw an exception

### Updated
*   Updated documentation

## 2.5.3 - 2024-11-16

### Added
*   Implement Feature Request: Implement Docker ENV variable for --cleanup-local-files
*   Enhancement: Setup a specific SIGPIPE Signal handler for curl/openssl generated signals
*   Enhancement: Add Check Spelling GitHub Action
*   Enhancement: Add passive database checkpoints to optimise database operations
*   Enhancement: Ensure application notifies user of curl versions that contain HTTP/2 bugs that impact the operation of this client
*   Enhancement: Add OpenSSL version warning
*   Enhancement: Improve performance with reduced execution time and lower CPU/system resource usage

### Changed
*   Specifically use a 'mutex' to perform the lock on database actions
*   Update safeBackup to use a new filename format for easier identification: filename-hostname-safeBackup-number.file_extension
*   Allow no-sync operations to complete online account checks

### Fixed
*   Fix Regression: Fix regression for Docker 'sync_dir' use
*   Fix Bug: Fix that a 'sync_list' entry of '/' will cause a index [0] is out of bounds
*   Fix Bug: Fix that when creating a new folder online the application generates an exception if it is in a Shared Online Folder
*   Fix Bug: Fix application crash when session upload files contain zero data or are corrupt
*   Fix Bug: Fix that curl generates a SIGPIPE that causes application to exit due to upstream device killing idle TCP connection
*   Fix Bug: Fix that skip_dir is not flagging directories correctly causing deletion if parental path structure needs to be created for sync_list handling
*   Fix Bug: Fix application crash caused by unable to drop table
*   Fix Bug: Fix that skip_file in config does not override defaults
*   Fix Bug: Handle DB upgrades from v2.4.x without causing application crash
*   Fix Bug: Fix a database statement execution error occurred: NOT NULL constraint failed: item.type due to Microsoft OneNote items
*   Fix Bug: Fix Operation not permitted FileException Error when attempting to use setTimes() function
*   Fix Bug: Fix that files with no mime type cause sync to crash
*   Fix Bug: Fix that bypass_data_preservation operates as intended

### Updated
*   Fixed spelling errors across all documentation and code
*   Update Dockerfile-debian to fix that libcurl4 does not get applied despite being pulled in. Explicitly install it from Debian 12 Backports
*   Add Ubuntu 24.10 OpenSuSE Build Service details
*   Update Dockerfile-alpine - revert to Alpine 3.19 as application fails to run on Alpine 3.20
*   Updated documentation

## 2.5.2 - 2024-09-29

### Added
*   Added 15 second sleep to systemd services to allow d-bus daemon to start and be available if present

### Fixed
*   Fix Bug: Application crash unable to correctly process a timestamp that has fractional seconds
*   Fix Bug: Fixed application logging output of Personal Shared Folder incorrectly advising there is no free space

### Updated
*   Updated documentation

## 2.5.1 - 2024-09-27 (DO NOT USE. CONTAINS A MAJOR TIMESTAMP ISSUE BUG)

### Special Thankyou
A special thankyou to @phlibi for assistance with diagnosing and troubleshooting the database timestamp issue

### Added
*   Implement Feature Request: Don't print the d-bus WARNING if disable_notifications is set on cmd line or in config

### Changed
*   Add --enable-debug to Docker files when building client application to allow for better diagnostics when issues occur
*   Update Debian Dockerfile to use 'curl' from backports so a more modern curl version is used

### Fixed
*   Fix Regression: Fix regression of extra quotation marks when using ONEDRIVE_SINGLE_DIRECTORY with Docker
*   Fix Regression: Fix regression that real-time synchronization is not occurring when using --monitor and sync_list
*   Fix Regression: Fix regression that --remove-source-files doesn’t work
*   Fix Bug: Application crash when run synchronize due to negative free space online
*   Fix Bug: Application crash when performing a URL decode
*   Fix Bug: Application crash when using sync_list and Personal Shared Folders the root folder fails to present the item id
*   Fix Bug: Application crash when attempting to read timestamp from database as invalid data was written

### Updated
*   Updated documentation (various)

## 2.5.0 - 2024-09-16

### Special Thankyou
A special thankyou to all those who helped with testing and providing feedback during the development of this major release. A big thankyou to:
*   @JC-comp
*   @Lyncredible
*   @rrodrigueznt
*   @bpozdena
*   @hskrieg
*   @robertschulze 
*   @aothmane-control
*   @mozram
*   @LunCh-CECNL
*   @pkolmann
*   @tdcockers
*   @undefiened
*   @cyb3rko

### Notable Changes
*   This version introduces significant changes regarding how the integrity and validation of your data is determined and is not backwards compatible with v2.4.x.
*   OneDrive Business Shared Folder Sync has been 100% re-written in v2.5.0. If you are using this feature, please read the new documentation carefully.
*   The application function --download-only no longer automatically deletes local files. Please read the new documentation regarding this feature.

### Added
*   Implement Feature Request: Multi-threaded uploading/downloading of files
*   Implement Feature Request: Renaming/Relocation of OneDrive Business shared folders
*   Implement Feature Request: Support the syncing of individual business shared files
*   Implement Feature Request: Implement application output to detail upload|download failures at the end of a sync process
*   Implement Feature Request: Log when manual Authorization is required when using --auth-files
*   Implement Feature Request: Add cmdline parameter to display (human readable) quota status
*   Implement Feature Request: Add capability to disable 'fullscan_frequency'
*   Implement Feature Request: Ability to set --disable-download-validation from Docker environment variable
*   Implement Feature Request: Ability to set --sync-shared-files from Docker environment variable
*   Implement Feature Request: file sync (upload/download/delete) notifications

### Changed
*   Renamed various documentation files to align with document content
*   Implement buffered logging so that all logging from all upload & download activities are handled correctly
*   Replace polling monitor loop with blocking wait
*   Update how the application utilises curl to fix socket reuse
*   Various performance enhancements
*   Implement refactored OneDrive API logic
*   Enforcement of operational conflicts
*   Enforcement of application configuration defaults and minimums
*   Utilise threadsafe sqlite DB access methods
*   Various bugs and other issues identified during development and testing
*   Various code cleanup and optimisations

### Fixed
*   Fix Bug: Upload only not working with Business shared folders
*   Fix Bug: Business shared folders with same basename get merged
*   Fix Bug: --dry-run prevents authorization
*   Fix Bug: Log timestamps lacking trailing zeros, leading to poor log file output alignment
*   Fix Bug: Subscription ID already exists when using webhooks
*   Fix Bug: Not all files being downloaded when API data includes HTML ASCII Control Sequences
*   Fix Bug: --display-sync-status does not work when OneNote sections (.one files) are in your OneDrive
*   Fix Bug: vim backups when editing files cause edited file to be deleted rather than the edited file being uploaded
*   Fix Bug: skip_dir does not always work as intended for all directory entries
*   Fix Bug: Online date being changed in download-only mode
*   Fix Bug: Resolve that download_only = "true" and cleanup_local_files = "true" also deletes files present online
*   Fix Bug: Resolve that upload session are not canceled with resync option
*   Fix Bug: Local files should be safely backed up when the item is not in sync locally to prevent data loss when they are deleted online
*   Fix Bug: Files with newer timestamp are not chosen as version to be kept
*   Fix Bug: Synced file is removed when updated on the remote while being processed by onedrive
*   Fix Bug: Cannot select/filter within Personal Shared Folders
*   Fix Bug: HTML encoding requires to add filter entries twice
*   Fix Bug: Uploading files using fragments stuck at 0%
*   Fix Bug: Implement safeguard when sync_dir is missing and is re-created data is not deleted online
*   Fix Bug: Fix that --get-sharepoint-drive-id does not handle a SharePoint site with more than 200 entries
*   Fix Bug: Fix that 'sync_list' does not include files that should be included, when specified just as *.ext_type
*   Fix Bug: Fix 'sync_list' processing so that '.folder_name' is excluded but 'folder_name' is included

### Updated
*   Overhauled all documentation

## 2.4.25 - 2023-06-21

### Fixed
*   Fixed that the application was reporting as v2.2.24 when in fact it was v2.4.24 (release tagging issue)
*   Fixed that the running version obsolete flag (due to above issue) was causing a false flag as being obsolete
*   Fixed that zero-byte files do not have a hash as reported by the OneDrive API thus should not generate an error message

### Updated
*   Update to Debian Docker file to resolve Docker image Operating System reported vulnerabilities
*   Update to Alpine Docker file to resolve Docker image Operating System reported vulnerabilities
*   Update to Fedora Docker file to resolve Docker image Operating System reported vulnerabilities
*   Updated documentation (various)

## 2.4.24 - 2023-06-20
### Fixed
*   Fix for extra encoded quotation marks surrounding Docker environment variables
*   Fix webhook subscription creation for SharePoint Libraries
*   Fix that a HTTP 504 - Gateway Timeout causes local files to be deleted when using --download-only & --cleanup-local-files mode
*   Fix that folders are renamed despite using --dry-run
*   Fix deprecation warnings with dmd 2.103.0
*   Fix error that the application is unable to perform a database vacuum: out of memory when exiting

### Removed
*   Remove sha1 from being used by the client as this is being deprecated by Microsoft in July 2023
*   Complete the removal of crc32 elements

### Added
*   Added ONEDRIVE_SINGLE_DIRECTORY configuration capability to Docker
*   Added --get-file-link shell completion
*   Added configuration to allow HTTP session timeout(s) tuning via config (taken from v2.5.x)

### Updated
*   Update to Debian Docker file to resolve Docker image Operating System reported vulnerabilities
*   Update to Alpine Docker file to resolve Docker image Operating System reported vulnerabilities
*   Update to Fedora Docker file to resolve Docker image Operating System reported vulnerabilities
*   Updated cgi.d to commit 680003a - last upstream change before requiring `core.d` dependency requirement
*   Updated documentation (various)

## 2.4.23 - 2023-01-06
### Fixed
*   Fixed RHEL7, RHEL8 and RHEL9 Makefile and SPEC file compatibility

### Removed
*   Disable systemd 'PrivateUsers' due to issues with systemd running processes when option is enabled, causes local file deletes on RHEL based systems

### Updated
*   Update --get-O365-drive-id error handling to display a more a more appropriate error message if the API cannot be found
*   Update the GitHub version check to utilise the date a release was done, to allow 1 month grace period before generating obsolete version message
*   Update Alpine Dockerfile to use Alpine 3.17 and Golang 1.19
*   Update handling of --source-directory and --destination-directory if one is empty or missing and if used with --synchronize or --monitor
*   Updated documentation (various)

## 2.4.22 - 2022-12-06
### Fixed
*   Fix application crash when local file is changed to a symbolic link with non-existent target
*   Fix build error with dmd-2.101.0
*   Fix build error with LDC 1.28.1 on Alpine
*   Fix issue of silent exit when unable to delete local files when using --cleanup-local-files
*   Fix application crash due to access permissions on configured path for sync_dir
*   Fix potential application crash when exiting due to failure state and unable to cleanly shutdown the database
*   Fix creation of parent empty directories when parent is excluded by sync_list

### Added
*   Added performance output details for key functions

### Changed
*   Switch Docker 'latest' to point at Debian builds rather than Fedora due to ongoing Fedora build failures
*   Align application logging events to actual application defaults for --monitor operations
*   Performance Improvement: Avoid duplicate costly path calculations and DB operations if not required
*   Disable non-working remaining sandboxing options within systemd service files
*   Performance Improvement: Only check 'sync_list' if this has been enabled and configured
*   Display 'Sync with OneDrive is complete' when using --synchronize
*   Change the order of processing between Microsoft OneDrive restrictions and limitations check and skip_file|skip_dir check

### Removed
*   Remove building Fedora ARMv7 builds due to ongoing build failures

### Updated
*   Update config change detection handling
*   Updated documentation (various)

## 2.4.21 - 2022-09-27
### Fixed
*   Fix that the download progress bar doesn't always reach 100% when rate_limit is set
*   Fix --resync handling of database file removal
*   Fix Makefile to be consistent with permissions that are being used
*   Fix that logging output for skipped uploaded files is missing
*   Fix to allow non-sync tasks while sync is running
*   Fix where --resync is enforced for non-sync operations
*   Fix to resolve segfault when running 'onedrive --display-sync-status' when run as 2nd process
*   Fix DMD 2.100.2 depreciation warning

### Added
*   Add GitHub Action Test Build Workflow (replacing Travis CI)
*   Add option --display-running-config to display the running configuration as used at application startup
*   Add 'config' option to request readonly access in oauth authorization step
*   Add option --cleanup-local-files to cleanup local files regardless of sync state when using --download-only
*   Add option --with-editing-perms to create a read-write shareable link when used with --create-share-link <file>

### Changed
*   Change the exit code of the application to 126 when a --resync is required

### Updated
*   Updated --get-O365-drive-id implementation for data access
*   Update what application options require an argument
*   Update application logging output for error messages to remove certain \n prefix when logging to a file
*   Update onedrive.spec.in to fix error building RPM
*   Update GUI notification handling for specific skipped scenarios
*   Updated documentation (various)

## 2.4.20 - 2022-07-20
### Fixed
*   Fix 'foreign key constraint failed' when using OneDrive Business Shared Folders due to change to using /delta query
*   Fix various little spelling errors (checked with lintian during Debian packaging)
*   Fix handling of a custom configuration directory when using --confdir
*   Fix to ensure that any active http instance is shutdown before any application exit
*   Fix to enforce that --confdir must be a directory

### Added
*   Added 'force_http_11' configuration option to allow forcing HTTP/1.1 operations

### Changed
*   Increased thread sleep for better process I/O wait handling
*   Removed 'force_http_2' configuration option

### Updated
*   Update OneDrive API response handling for National Cloud Deployments
*   Updated to switch to using curl defaults for HTTP/2 operations
*   Updated documentation (various)

## 2.4.19 - 2022-06-15
### Fixed
*   Update Business Shared Folders to use a /delta query
*   Update when DB is updated by OneDrive API data and update when file hash is required to be generated

### Added
*   Added ONEDRIVE_UPLOADONLY flag for Docker

### Updated
*   Updated GitHub workflows
*   Updated documentation (various)

## 2.4.18 - 2022-06-02
### Fixed
*   Fixed various database related access issues stemming from running multiple instances of the application at the same time using the same configuration data
*   Fixed --display-config being impacted by --resync flag
*   Fixed installation permissions for onedrive man-pages file
*   Fixed that in some situations that users try --upload-only and --download-only together which is not possible
*   Fixed application crash if unable to read required hash files

### Added
*   Added Feature Request to add an override for skip_dir|skip_file through flag to force sync
*   Added a check to validate local filesystem available space before attempting file download
*   Added GitHub Actions to build Docker containers and push to DockerHub 

### Updated
*   Updated all Docker build files to current distributions, using updated distribution LDC version
*   Updated logging output to logfiles when an actual sync process is occurring
*   Updated output of --display-config to be more relevant
*   Updated manpage to align with application configuration
*   Updated documentation and Docker files based on minimum compiler versions to dmd-2.088.0 and ldc-1.18.0
*   Updated documentation (various)

## 2.4.17 - 2022-04-30
### Fixed
*   Fix docker build, by add missing git package for Fedora builds
*   Fix application crash when attempting to sync a broken symbolic link
*   Fix Internet connect disruption retry handling and logging output
*   Fix local folder creation timestamp with timestamp from OneDrive
*   Fix logging output when download failed

### Added
*   Add additional logging specifically for delete event to denote in log output the source of a deletion event when running in --monitor mode

### Changed
*   Improve when the local database integrity check is performed and on what frequency the database integrity check is performed

### Updated
*   Remove application output ambiguity on how to access 'help' for the client
*   Update logging output when running in --monitor --verbose mode in regards to the inotify events
*   Updated documentation (various)

## 2.4.16 - 2022-03-10
### Fixed
*   Update application file logging error handling
*   Explicitly set libcurl options
*   Fix that when a sync_list exclusion is matched, the item needs to be excluded when using --resync
*   Fix so that application can be compiled correctly on Android hosts
*   Fix the handling of 429 and 5xx responses when they are generated by OneDrive in a self-referencing circular pattern
*   Fix applying permissions to volume directories when running in rootless podman
*   Fix unhandled errors from OneDrive when initialising subscriptions fail

### Added
*   Enable GitHub Sponsors
*   Implement --resync-auth to enable CLI passing in of --rsync approval
*   Add function to check client version vs latest GitHub release
*   Add --reauth to allow easy re-authentication of the client
*   Implement --modified-by to display who last modified a file and when the modification was done
*   Implement feature request to mark partially-downloaded files as .partial during download
*   Add documentation for Podman support

### Changed
*   Document risk regarding using --resync and force user acceptance of usage risk to proceed
*   Use YAML for Bug Reports and Feature Requests
*   Update Dockerfiles to use more modern base Linux distribution

### Updated
*   Updated documentation (various)

## 2.4.15 - 2021-12-31
### Fixed
*   Fix unable to upload to OneDrive Business Shared Folders due to OneDrive API restricting quota information
*   Update fixing edge case with OneDrive Personal Shared Folders and --resync --upload-only

### Added
*   Add SystemD hardening
*   Add --operation-timeout argument

### Changed
*   Updated minimum compiler versions to dmd-2.087.0 and ldc-1.17.0

### Updated
*   Updated Dockerfile-alpine to use Alpine 3.14
*   Updated documentation (various)

## 2.4.14 - 2021-11-24
### Fixed
*   Support DMD 2.097.0 as compiler for Docker Builds
*   Fix getPathDetailsByDriveId query when using --dry-run and a nested path with --single-directory
*   Fix edge case when syncing OneDrive Personal Shared Folders
*   Catch unhandled API response errors when querying OneDrive Business Shared Folders
*   Catch unhandled API response errors when listing OneDrive Business Shared Folders
*   Fix error 'Key not found: remaining' with Business Shared Folders (OneDrive API change)
*   Fix overwriting local files with older versions from OneDrive when items.sqlite3 does not exist and --resync is not used

### Added
*   Added operation_timeout as a new configuration to assist in cases where operations take longer that 1h to complete
*   Add Real-Time syncing of remote updates via webhooks
*   Add --auth-response option and expose through entrypoint.sh for Docker
*   Add --disable-download-validation

### Changed
*   Always prompt for credentials for authentication rather than re-using cached browser details
*   Do not re-auth on --logout

### Updated
*   Updated documentation (various)

## 2.4.13 - 2021-7-14
### Fixed
*   Support DMD 2.097.0 as compiler
*   Fix to handle OneDrive API Bad Request response when querying if file exists
*   Fix application crash and incorrect handling of --single-directory when syncing a OneDrive Business Shared Folder due to using 'Add Shortcut to My Files'
*   Fix application crash due to invalid UTF-8 sequence in the pathname for the application configuration
*   Fix error message when deleting a large number of files
*   Fix Docker build process to source GOSU keys from updated GPG key location
*   Fix application crash due to a conversion overflow when calculating file offset for session uploads
*   Fix Docker Alpine build failing due to filesystem permissions issue due to Docker build system and Alpine Linux 3.14 incompatibility
*   Fix that Business Shared Folders with parentheses are ignored

### Updated
*   Updated Lock Bot to run daily
*   Updated documentation (various)

## 2.4.12 - 2021-5-28
### Fixed
*   Fix an unhandled Error 412 when uploading modified files to OneDrive Business Accounts
*   Fix 'sync_list' handling of inclusions when name is included in another folders name
*   Fix that options --upload-only & --remove-source-files are ignored on an upload session restore
*   Fix to add file check when adding item to database if using --upload-only --remove-source-files
*   Fix application crash when SharePoint displayName is being withheld

### Updated
*   Updated Lock Bot to use GitHub Actions
*   Updated documentation (various)

## 2.4.11 - 2021-4-07
### Fixed
*   Fix support for '/*' regardless of location within sync_list file
*   Fix 429 response handling correctly check for 'retry-after' response header and use set value
*   Fix 'sync_list' path handling for sub item matching, so that items in parent are not implicitly matched when there is no wildcard present
*   Fix --get-O365-drive-id to use 'nextLink' value if present when searching for specific SharePoint site names
*   Fix OneDrive Business Shared Folder existing name conflict check
*   Fix incorrect error message 'Item cannot be deleted from OneDrive because it was not found in the local database' when item is actually present
*   Fix application crash when unable to rename folder structure due to unhandled file-system issue
*   Fix uploading documents to Shared Business Folders when the shared folder exists on a SharePoint site due to Microsoft Sharepoint 'enrichment' of files
*   Fix that a file record is kept in database when using --no-remote-delete & --remove-source-files

### Added
*   Added support in --get-O365-drive-id to provide the 'drive_id' for multiple 'document libraries' within a single Shared Library Site

### Removed
*   Removed the deprecated config option 'force_http_11' which was flagged as deprecated by PR #549 in v2.3.6 (June 2019)

### Updated
*   Updated error output of --get-O365-drive-id to provide more details why an error occurred if a SharePoint site lacks the details we need to perform the match
*   Updated Docker build files for Raspberry Pi to dedicated armhf & aarch64 Dockerfiles
*   Updated logging output when in --monitor mode, avoid outputting misleading logging when the new or modified item is a file, not a directory
*   Updated documentation (various)

## 2.4.10 - 2021-2-19
### Fixed
*   Catch database assertion when item path cannot be calculated
*   Fix alpine Docker build so it uses the same golang alpine version
*   Search all distinct drive id's rather than just default drive id for --get-file-link
*   Use correct driveId value to query for changes when using --single-directory
*   Improve upload handling of files for SharePoint sites and detecting when SharePoint modifies the file post upload
*   Correctly handle '~' when present in 'log_dir' configuration option
*   Fix logging output when handing downloaded new files
*   Fix to use correct path offset for sync_list exclusion matching 

### Added
*   Add upload speed metrics when files are uploaded and clarify that 'data to transfer' is what is needed to be downloaded from OneDrive
*   Add new config option to rate limit connection to OneDrive
*   Support new file maximum upload size of 250GB
*   Support sync_list matching full path root wildcard with exclusions to simplify sync_list configuration

### Updated
*   Rename Office365.md --> SharePoint-Shared-Libraries.md which better describes this document
*   Updated Dockerfile config for arm64
*   Updated documentation (various)

## 2.4.9 - 2020-12-27
### Fixed
*   Fix to handle case where API provided deltaLink generates a further API error
*   Fix application crash when unable to read a local file due to local file permissions
*   Fix application crash when calculating the path length due to invalid UTF characters in local path
*   Fix Docker build on Alpine due missing symbols due to using the edge version of ldc and ldc-runtime
*   Fix application crash with --get-O365-drive-id when API response is restricted

### Added
*   Add debug log output of the configured URL's which will be used throughout the application to remove any ambiguity as to using incorrect URL's when making API calls
*   Improve application startup when using --monitor when there is no network connection to the OneDrive API and only initialise application once OneDrive API is reachable
*   Add Docker environment variable to allow --logout for re-authentication

### Updated
*   Remove duplicate code for error output functions and enhance error logging output
*   Updated documentation

## 2.4.8 - 2020-11-30
### Fixed
*   Fix to use config set option for 'remove_source_files' and 'skip_dir_strict_match' rather than ignore if set
*   Fix download failure and crash due to incorrect local filesystem permissions when using mounted external devices
*   Fix to not change permissions on pre-existing local directories
*   Fix logging output when authentication authorisation fails to not say authorisation was successful
*   Fix to check application_id before setting redirect URL when using specific Azure endpoints
*   Fix application crash in --monitor mode due to 'Failed to stat file' when setgid is used on a directory and data cannot be read

### Added
*   Added advanced-usage.md to document advanced client usage such as multi account configurations and Windows dual-boot

### Updated
*   Updated --verbose logging output for config options when set
*   Updated documentation (man page, USAGE.md, Office365.md, BusinessSharedFolders.md)

## 2.4.7 - 2020-11-09
### Fixed
*   Fix debugging output for /delta changes available queries
*   Fix logging output for modification comparison source data
*   Fix Business Shared Folder handling to process only Shared Folders, not individually shared files
*   Fix cleanup dryrun shm and wal files if they exist
*   Fix --list-shared-folders to only show folders
*   Fix to check for the presence of .nosync when processing DB entries
*   Fix skip_dir matching when using --resync
*   Fix uploading data to shared business folders when using --upload-only
*   Fix to merge contents of SQLite WAL file into main database file on sync completion
*   Fix to check if localModifiedTime is >= than item.mtime to avoid re-upload for equal modified time
*   Fix to correctly set config directory permissions at first start

### Added
*   Added environment variable to allow easy HTTPS debug in docker
*   Added environment variable to allow download-only mode in Docker
*   Implement Feature: Allow config to specify a tenant id for non-multi-tenant applications
*   Implement Feature: Adding support for authentication with single tenant custom applications
*   Implement Feature: Configure specific File and Folder Permissions

### Updated
*   Updated documentation (readme.md, install.md, usage.md, bug_report.md)

## 2.4.6 - 2020-10-04
### Fixed
*   Fix flagging of remaining free space when value is being restricted
*   Fix --single-directory path handling when path does not exist locally
*   Fix checking for 'Icon' path as no longer listed by Microsoft as an invalid file or folder name
*   Fix removing child items on OneDrive when parent item responds with access denied
*   Fix to handle deletion events for files when inotify events are missing
*   Fix uninitialised value error as reported by valgrind
*   Fix to handle deletion events for directories when inotify events are missing

### Added
*   Implement Feature: Create shareable link
*   Implement Feature: Support wildcard within sync_list entries
*   Implement Feature: Support negative patterns in sync_list for fine grained exclusions
*   Implement Feature: Multiple skip_dir & skip_file configuration rules
*   Add GUI notification to advise users when the client needs to be reauthenticated

### Updated
*   Updated documentation (readme.md, install.md, usage.md, bug_report.md)

## 2.4.5 - 2020-08-13
### Fixed
*   Fixed fish auto completions installation destination

## 2.4.4 - 2020-08-11
### Fixed
*   Fix 'skip_dir' & 'skip_file' pattern matching to ensure correct matching is performed
*   Fix 'skip_dir' & 'skip_file' so that each directive is only used against directories or files as required in --monitor
*   Fix client hand when attempting to sync a Unix pipe file
*   Fix --single-directory & 'sync_list' performance 
*   Fix erroneous 'return' statements which could prematurely end processing all changes returned from OneDrive
*   Fix segfault when attempting to perform a comparison on an inotify event when determining if event path is directory or file
*   Fix handling of Shared Folders to ensure these are checked against 'skip_dir' entries
*   Fix 'Skipping uploading this new file as parent path is not in the database' when uploading to a Personal Shared Folder
*   Fix how available free space is tracked when uploading files to OneDrive and Shared Folders
*   Fix --single-directory handling of parent path matching if path is being seen for first time

### Added
*   Added Fish auto completions

### Updated
*   Increase maximum individual file size to 100GB due to Microsoft file limit increase
*   Update Docker build files and align version of compiler across all Docker builds
*   Update Docker documentation
*   Update NixOS build information
*   Update the 'Processing XXXX' output to display the full path
*   Update logging output when a sync starts and completes when using --monitor
*   Update Office 365 / SharePoint site search query and response if query return zero match

## 2.4.3 - 2020-06-29
### Fixed
*   Check if symbolic link is relative to location path
*   When using output logfile, fix inconsistent output spacing
*   Perform initial sync at startup in monitor mode
*   Handle a 'race' condition to process inotify events generated whilst performing DB or filesystem walk
*   Fix segfault when moving folder outside the sync directory when using --monitor on Arch Linux

### Added
*   Added additional inotify event debugging
*   Added support for loading system configs if there's no user config
*   Added Ubuntu installation details to include installing the client from a PPA
*   Added openSUSE installation details to include installing the client from a package
*   Added support for comments in sync_list file
*   Implement recursive deletion when Retention Policy is enabled on OneDrive Business Accounts
*   Implement support for National cloud deployments
*   Implement OneDrive Business Shared Folders Support

### Updated
*   Updated documentation files (various)
*   Updated log output messaging when a full scan has been set or triggered
*   Updated buildNormalizedPath complexity to simplify code
*   Updated to only process OneDrive Personal Shared Folders only if account type is 'personal'

## 2.4.2 - 2020-05-27
### Fixed
*   Fixed the catching of an unhandled exception when inotify throws an error
*   Fixed an uncaught '100 Continue' response when files are being uploaded
*   Fixed progress bar for uploads to be more accurate regarding percentage complete
*   Fixed handling of database query enforcement if item is from a shared folder
*   Fixed compiler depreciation of std.digest.digest
*   Fixed checking & loading of configuration file sequence
*   Fixed multiple issues reported by Valgrind
*   Fixed double scan at application startup when using --monitor & --resync together
*   Fixed when renaming a file locally, ensure that the target filename is valid before attempting to upload to OneDrive
*   Fixed so that if a file is modified locally and --resync is used, rename the local file for data preservation to prevent local data loss

### Added
*   Implement 'bypass_data_preservation' enhancement

### Changed
*   Changed the monitor interval default to 300 seconds

### Updated
*   Updated the handling of out-of-space message when OneDrive is out of space
*   Updated debug logging for retry wait times

## 2.4.1 - 2020-05-02
### Fixed
*   Fixed the handling of renaming files to a name starting with a dot when skip_dotfiles = true
*   Fixed the handling of parentheses from path or file names, when doing comparison with regex
*   Fixed the handling of renaming dotfiles to another dotfile when skip_dotfile=true in monitor mode
*   Fixed the handling of --dry-run and --resync together correctly as current database may be corrupt
*   Fixed building on Alpine Linux under Docker
*   Fixed the handling of --single-directory for --dry-run and --resync scenarios
*   Fixed the handling of .nosync directive when downloading new files into existing directories that is (was) in sync
*   Fixed the handling of zero-byte modified files for OneDrive Business
*   Fixed skip_dotfiles handling of .folders when in monitor mode to prevent monitoring
*   Fixed the handling of '.folder' -> 'folder' move when skip_dotfiles is enabled
*   Fixed the handling of folders that cannot be read (permission error) if parent should be skipped
*   Fixed the handling of moving folders from skipped directory to non-skipped directory via OneDrive web interface
*   Fixed building on CentOS Linux under Docker
*   Fixed Codacy reported issues: double quote to prevent globbing and word splitting
*   Fixed an assertion when attempting to compute complex path comparison from shared folders
*   Fixed the handling of .folders when being skipped via skip_dir

### Added
*   Implement Feature: Implement the ability to set --resync as a config option, default is false

### Updated
*   Update error logging to be consistent when initialising fails
*   Update error logging output to handle HTML error response reasoning if present
*   Update link to new Microsoft documentation
*   Update logging output to differentiate between OneNote objects and other unsupported objects
*   Update RHEL/CentOS spec file example
*   Update known-issues.md regarding 'SSL_ERROR_SYSCALL, errno 104'
*   Update progress bar to be more accurate when downloading large files
*   Updated #658 and #865 handling of when to trigger a directory walk when changes occur on OneDrive
*   Updated handling of when a full scan is required due to utilising sync_list
*   Updated handling of when OneDrive service throws a 429 or 504 response to retry original request after a delay

## 2.4.0 - 2020-03-22
### Fixed
*   Fixed how the application handles 429 response codes from OneDrive (critical update)
*   Fixed building on Alpine Linux under Docker
*   Fixed how the 'username' is determined from the running process for logfile naming
*   Fixed file handling when a failed download has occurred due to exiting via CTRL-C
*   Fixed an unhandled exception when OneDrive throws an error response on initialising
*   Fixed the handling of moving files into a skipped .folder when skip_dotfiles = true
*   Fixed the regex parsing of response URI to avoid potentially generating a bad request to OneDrive, leading to a 'AADSTS9002313: Invalid request. Request is malformed or invalid.' response.

### Added
*   Added a Dockerfile for building on Raspberry Pi / ARM platforms
*   Implement Feature: warning on big deletes to safeguard data on OneDrive
*   Implement Feature: delete local files after sync
*   Implement Feature: perform skip_dir explicit match only
*   Implement Feature: provide config file option for specifying the Client Identifier

### Changed
*   Updated the 'Client Identifier' to a new Application ID

### Updated
*   Updated relevant documentation (README.md, USAGE.md) to add new feature details and clarify existing information
*   Update completions to include the --force-http-2 option
*   Update to always log when a file is skipped due to the item being invalid
*   Update application output when just authorising application to make information clearer
*   Update logging output when using sync_list to be clearer as to what is actually being processed and why

## 2.3.13 - 2019-12-31
### Fixed
*   Change the sync list override flag to false as default when not using sync_list
*   Fix --dry-run output when using --upload-only & --no-remote-delete and deleting local files

### Added
*   Add a verbose log entry when a monitor sync loop with OneDrive starts & completes

### Changed
*   Remove logAndNotify for 'processing X changes' as it is excessive for each change bundle to inform the desktop of the number of changes the client is processing

### Updated
*   Updated INSTALL.md with Ubuntu 16.x i386 build instructions to reflect working configuration on legacy hardware
*   Updated INSTALL.md with details of Linux packages
*   Updated INSTALL.md build instructions for CentOS platforms

## 2.3.12 - 2019-12-04
### Fixed
*   Retry session upload fragment when transient errors occur to prevent silent upload failure
*   Update Microsoft restriction and limitations about windows naming files to include '~' for folder names
*   Docker guide fixes, add multiple account setup instructions
*   Check database for excluded sync_list items previously in scope
*   Catch DNS resolution error
*   Fix where an item now out of scope should be flagged for local delete
*   Fix rebuilding of onedrive, but ensure version is properly updated 
*   Update Ubuntu i386 build instructions to use DMD using preferred method

### Added
*   Add debug message to when a message is sent to dbus or notification daemon
*   Add i386 instructions for legacy low memory platforms using LDC

## 2.3.11 - 2019-11-05
### Fixed
*   Fix typo in the documentation regarding invalid config when upgrading from 'skilion' codebase
*   Fix handling of skip_dir, skip_file & sync_list config options
*   Fix typo in the documentation regarding sync_list
*   Fix log output to be consistent with sync_list exclusion
*   Fix 'Processing X changes' output to be more reflective of actual activity when using sync_list
*   Remove unused and unexported SED variable in Makefile.in 
*   Handle curl exceptions and timeouts better with backoff/retry logic
*   Update skip_dir pattern matching when using wildcards
*   Fix when a full rescan is performed when using sync_list
*   Fix 'Key not found: name' when computing skip_dir path
*   Fix call from --monitor to observe --no-remote-delete
*   Fix unhandled exception when monitor initialisation failure occurs due to too many open local files
*   Fix unhandled 412 error response from OneDrive API when moving files right after upload
*   Fix --monitor when used with --download-only. This fixes a regression introduced in 12947d1.
*   Fix if --single-directory is being used, and we are using --monitor, only set inotify watches on the single directory

### Changed
*   Move JSON logging output from error messages to debug output

## 2.3.10 - 2019-10-01
### Fixed
*   Fix searching for 'name' when deleting a synced item, if the OneDrive API does not return the expected details in the API call
*   Fix abnormal termination when no Internet connection
*   Fix downloading of files from OneDrive Personal Shared Folders when the OneDrive API responds with unexpected additional path data
*   Fix logging of 'initialisation' of client to actually when the attempt to initialise is performed
*   Fix when using a sync_list file, using deltaLink will actually 'miss' changes (moves & deletes) on OneDrive as using sync_list discards changes
*   Fix OneDrive API status code 500 handling when uploading files as error message is not correct
*   Fix crash when resume_upload file is not a valid JSON 
*   Fix crash when a file system exception is generated when attempting to update the file date & time and this fails

### Added
*   If there is a case-insensitive match error, also return the remote name from the response
*   Make user-agent string a configuration option & add to config file
*   Set default User-Agent to 'OneDrive Client for Linux v{version}'

### Changed
*   Make verbose logging output optional on Docker
*   Enable --resync & debug client output via environment variables on Docker

## 2.3.9 - 2019-09-01
### Fixed
*   Catch a 403 Forbidden exception when querying Sharepoint Library Names
*   Fix unhandled error exceptions that cause application to exit / crash when uploading files
*   Fix JSON object validation for queries made against OneDrive where a JSON response is expected and where that response is to be used and expected to be valid
*   Fix handling of 5xx responses from OneDrive when uploading via a session

### Added
*   Detect the need for --resync when config changes either via config file or cli override

### Changed
*   Change minimum required version of LDC to v1.12.0

### Removed
*   Remove redundant logging output due to change in how errors are reported from OneDrive

## 2.3.8 - 2019-08-04
### Fixed
*   Fix unable to download all files when OneDrive fails to return file level details used to validate file integrity
*   Included the flag "-m" to create the home directory when creating the user
*   Fix entrypoint.sh to work with "sudo docker run"
*   Fix docker build error on stretch
*   Fix hidden directories in 'root' from having prefix removed
*   Fix Sharepoint Document Library handling for .txt & .csv files
*   Fix logging for init.d service
*   Fix OneDrive response missing required 'id' element when uploading images
*   Fix 'Unexpected character '<'. (Line 1:1)' when OneDrive has an exception error
*   Fix error when creating the sync dir fails when there is no permission to create the sync dir

### Added
*   Add explicit check for hashes to be returned in cases where OneDrive API fails to provide them despite requested to do so
*   Add comparison with sha1 if OneDrive provides that rather than quickXor
*   Add selinux configuration details for a sync folder outside of the home folder
*   Add date tag on docker.hub
*   Add back CentOS 6 install & uninstall to Makefile
*   Add a check to handle moving items out of sync_list sync scope & delete locally if true
*   Implement --get-file-link which will return the weburl of a file which has been synced to OneDrive

### Changed
*   Change unauthorized-api exit code to 3
*   Update LDC to v1.16.0 for Travis CI testing
*   Use replace function for modified Sharepoint Document Library files rather than delete and upload as new file, preserving file history
*   Update Sharepoint modified file handling for files > 4Mb in size

### Removed
*   Remove -d shorthand for --download-only to avoid confusion with other GNU applications where -d stands for 'debug'

## 2.3.7 - 2019-07-03
### Fixed
*   Fix not all files being downloaded due to OneDrive query failure
*   False DB update which potentially could had lead to false data loss on OneDrive

## 2.3.6 - 2019-07-03 (DO NOT USE)
### Fixed
*   Fix JSONValue object validation
*   Fix building without git being available
*   Fix some spelling/grammatical errors
*   Fix OneDrive error response on creating upload session

### Added
*   Add download size & hash check to ensure downloaded files are valid and not corrupt
*   Added --force-http-2 to use HTTP/2 if desired

### Changed
*   Deprecated --force-http-1.1 (enabled by default) due to OneDrive inconsistent behavior with HTTP/2 protocol

## 2.3.5 - 2019-06-19
### Fixed
*   Handle a directory in the sync_dir when no permission to access
*   Get rid of forced root necessity during installation
*   Fix broken autoconf code for --enable-XXX options
*   Fix so that skip_size check should only be used if configured
*   Fix a OneDrive Internal Error exception occurring before attempting to download a file

### Added
*   Check for supported version of D compiler

## 2.3.4 - 2019-06-13
### Fixed
*   Fix 'Local files not deleted' when using bad 'skip_file' entry
*   Fix --dry-run logging output for faking downloading new files
*   Fix install unit files to correct location on RHEL/CentOS 7
*   Fix up unit file removal on all platforms
*   Fix setting times on a file by adding a check to see if the file was actually downloaded before attempting to set the times on the file
*   Fix an unhandled curl exception when OneDrive throws an internal timeout error
*   Check timestamp to ensure that latest timestamp is used when comparing OneDrive changes
*   Fix handling responses where cTag JSON elements are missing
*   Fix Docker entrypoint.sh failures when GID is defined but not UID

### Added
*   Add autoconf based build system
*   Add an encoding validation check before any path length checks are performed as if the path contains any invalid UTF-8 sequences
*   Implement --sync-root-files to sync all files in the OneDrive root when using a sync_list file that would normally exclude these files from being synced
*   Implement skip_size feature request
*   Implement feature request to support file based OneDrive authorization (request | response)

### Updated
*   Better handle initialisation issues when OneDrive / MS Graph is experiencing problems that generate 401 & 5xx error codes
*   Enhance error message when unable to connect to Microsoft OneDrive service when the local CA SSL certificate(s) have issues
*   Update Dockerfile to correctly build on Docker Hub
*   Rework directory layout and re-factor MD files for readability

## 2.3.3 - 2019-04-16
### Fixed
*   Fix --upload-only check for Sharepoint uploads
*   Fix check to ensure item root we flag as 'root' actually is OneDrive account 'root'
*   Handle object error response from OneDrive when uploading to OneDrive Business
*   Fix handling of some OneDrive accounts not providing 'quota' details
*   Fix 'resume_upload' handling in the event of bad OneDrive response

### Added
*   Add debugging for --get-O365-drive-id function
*   Add shell (bash,zsh) completion support
*   Add config options for command line switches to allow for better config handling in docker containers

### Updated
*   Implement more meaningful 5xx error responses
*   Update onedrive.logrotate indentations and comments
*   Update 'min_notif_changes' to 'min_notify_changes'

## 2.3.2 - 2019-04-02
### Fixed
*   Reduce scanning the entire local system in monitor mode for local changes
*   Resolve file creation loop when working directly in the synced folder and Microsoft Sharepoint

### Added
*   Add 'monitor_fullscan_frequency' config option to set the frequency of performing a full disk scan when in monitor mode

### Updated
*   Update default 'skip_file' to include tmp and lock files generated by LibreOffice
*   Update database version due to changing defaults of 'skip_file' which will force a rebuild and use of new skip_file default regex

## 2.3.1 - 2019-03-26
### Fixed
*   Resolve 'make install' issue where rebuild of application would occur due to 'version' being flagged as .PHONY
*   Update readme build instructions to include 'make clean;' before build to ensure that 'version' is cleanly removed and can be updated correctly
*   Update Debian Travis CI build URL's

## 2.3.0 - 2019-03-25
### Fixed
*   Resolve application crash if no 'size' value is returned when uploading a new file
*   Resolve application crash if a 5xx error is returned when uploading a new file
*   Resolve not 'refreshing' version file when rebuilding
*   Resolve unexpected application processing by preventing use of --synchronize & --monitor together
*   Resolve high CPU usage when performing DB reads
*   Update error logging around directory case-insensitive match
*   Update Travis CI and ARM dependencies for LDC 1.14.0
*   Update Makefile due to build failure if building from release archive file
*   Update logging as to why a OneDrive object was skipped

### Added
*   Implement config option 'skip_dir'

## 2.2.6 - 2019-03-12
### Fixed
*   Resolve application crash when unable to delete remote folders when business retention policies are enabled
*   Resolve deprecation warning: loop index implicitly converted from size_t to int
*   Resolve warnings regarding 'bashisms'
*   Resolve handling of notification failure is dbus server has not started or available
*   Resolve handling of response JSON to ensure that 'id' key element is always checked for
*   Resolve excessive & needless logging in monitor mode
*   Resolve compiling with LDC on Alpine as musl lacks some standard interfaces
*   Resolve notification issues when offline and cannot act on changes
*   Resolve Docker entrypoint.sh to accept command line arguments
*   Resolve to create a new upload session on reinit 
*   Resolve where on OneDrive query failure, default root and drive id is used if a response is not returned
*   Resolve Key not found: nextExpectedRanges when attempting session uploads and incorrect response is returned
*   Resolve application crash when re-using an authentication URI twice after previous --logout
*   Resolve creating a folder on a shared personal folder appears successful but returns a JSON error
*   Resolve to treat mv of new file as upload of mv target
*   Update Debian i386 build dependencies
*   Update handling of --get-O365-drive-id to print out all 'site names' that match the explicit search entry rather than just the last match
*   Update Docker readme & documentation
*   Update handling of validating local file permissions for new file uploads
### Added
*   Add support for install & uninstall on RHEL / CentOS 6.x
*   Add support for when notifications are enabled, display the number of OneDrive changes to process if any are found
*   Add 'config' option 'min_notif_changes' for minimum number of changes to notify on, default = 5
*   Add additional Docker container builds utilising a smaller OS footprint
*   Add configurable interval of logging in monitor mode
*   Implement new CLI option --skip-dot-files to skip .files and .folders if option is used
*   Implement new CLI option --check-for-nosync to ignore folder when special file (.nosync) present
*   Implement new CLI option --dry-run

## 2.2.5 - 2019-01-16
### Fixed
*   Update handling of HTTP 412 - Precondition Failed errors
*   Update --display-config to display sync_list if configured
*   Add a check for 'id' key on metadata update to prevent 'std.json.JSONException@std/json.d(494): Key not found: id'
*   Update handling of 'remote' folder designation as 'root' items
*   Ensure that remote deletes are handled correctly
*   Handle 'Item not found' exception when unable to query OneDrive 'root' for changes
*   Add handling for JSON response error when OneDrive API returns a 404 due to OneDrive API regression
*   Fix items highlighted by codacy review
### Added
*   Add --force-http-1.1 flag to downgrade any HTTP/2 curl operations to HTTP 1.1 protocol
*   Support building with ldc2 and usage of pkg-config for lib finding

## 2.2.4 - 2018-12-28
### Fixed
*   Resolve JSONException when supplying --get-O365-drive-id option with a string containing spaces
*   Resolve 'sync_dir' not read from 'config' file when run in Docker container
*   Resolve logic where potentially a 'default' ~/OneDrive sync_dir could be set despite 'config' file configured for an alternate
*   Make sure sqlite checkpointing works by properly finalizing statements
*   Update logic handling of --single-directory to prevent inadvertent local data loss
*   Resolve signal handling and database shutdown on SIGINT and SIGTERM
*   Update man page
*   Implement better help output formatting
### Added
*   Add debug handling for sync_dir operations
*   Add debug handling for homePath calculation
*   Add debug handling for configDirBase calculation
*   Add debug handling if syncDir is created
*   Implement Feature Request: Add status command or switch

## 2.2.3 - 2018-12-20
### Fixed
*   Fix syncdir option is ignored

## 2.2.2 - 2018-12-20
### Fixed
*   Handle short lived files in monitor mode
*   Provide better log messages, less noise on temporary timeouts
*   Deal with items that disappear during upload
*   Deal with deleted move targets
*   Reinitialize sync engine after three failed attempts
*   Fix activation of dmd for docker builds
*   Fix to check displayName rather than description for --get-O365-drive-id
*   Fix checking of config file keys for validity
*   Fix exception handling when missing parameter from usage option
### Added
*   Notification support via libnotify
*   Add very verbose (debug) mode by double -v -v
*   Implement option --display-config

## 2.2.1 - 2018-12-04
### Fixed
*   Gracefully handle connection errors in monitor mode 
*   Fix renaming of files when syncing 
*   Installation of doc files, addition of man page 
*   Adjust timeout values for libcurl 
*   Continue in monitor mode when sync timed out 
*   Fix unreachable statements 
*   Update Makefile to better support packaging 
*   Allow starting offline in monitor mode 
### Added
*   Implement --get-O365-drive-id to get correct SharePoint Shared Library (#248)
*   Docker buildfiles for onedrive service (#262) 

## 2.2.0 - 2018-11-24
### Fixed
*   Updated client to output additional logging when debugging
*   Resolve database assertion failure due to authentication
*   Resolve unable to create folders on shared OneDrive Personal accounts
### Added
*   Implement feature request to Sync from Microsoft SharePoint
*   Implement feature request to specify a logging directory if logging is enabled
### Changed
*   Change '--download' to '--download-only' to align with '--upload-only'
*   Change logging so that logging to a separate file is no longer the default

## 2.1.6 - 2018-11-15
### Fixed
*   Updated HTTP/2 transport handling when using curl 7.62.0 for session uploads
### Added
*   Added PKGBUILD for makepkg for building packages under Arch Linux

## 2.1.5 - 2018-11-11
### Fixed
*   Resolve 'Key not found: path' when syncing from some shared folders due to OneDrive API change
*   Resolve to only upload changes on remote folder if the item is in the database - dont assert if false
*   Resolve files will not download or upload when using curl 7.62.0 due to HTTP/2 being set as default for all curl operations
*   Resolve to handle HTTP request returned status code 412 (Precondition Failed) for session uploads to OneDrive Personal Accounts
*   Resolve unable to remove '~/.config/onedrive/resume_upload: No such file or directory' if there is a session upload error and the resume file does not get created
*   Resolve handling of response codes when using 2 different systems when using '--upload-only' but the same OneDrive account and uploading the same filename to the same location
### Updated
*   Updated Travis CI building on LDC v1.11.0 for ARMHF builds
*   Updated Makefile to use 'install -D -m 644' rather than 'cp -raf'
*   Updated default config to be aligned to code defaults

## 2.1.4 - 2018-10-10
### Fixed
*   Resolve syncing of OneDrive Personal Shared Folders due to OneDrive API change
*   Resolve incorrect systemd installation location(s) in Makefile

## 2.1.3 - 2018-10-04
### Fixed
*   Resolve File download fails if the file is marked as malware in OneDrive
*   Resolve high CPU usage when running in monitor mode
*   Resolve how default path is set when running under systemd on headless systems
*   Resolve incorrectly nested configDir in X11 systems
*   Resolve Key not found: driveType
*   Resolve to validate filename length before download to conform with Linux FS limits
*   Resolve file handling to look for HTML ASCII codes which will cause uploads to fail
*   Resolve Key not found: expirationDateTime on session resume
### Added
*   Update Travis CI building to test build on ARM64

## 2.1.2 - 2018-08-27
### Fixed
*   Resolve skipping of symlinks in monitor mode
*   Resolve Gateway Timeout - JSONValue is not an object
*   Resolve systemd/user is not supported on CentOS / RHEL
*   Resolve HTTP request returned status code 429 (Too Many Requests)
*   Resolve handling of maximum path length calculation
*   Resolve 'The parent item is not in the local database'
*   Resolve Correctly handle file case sensitivity issues in same folder
*   Update unit files documentation link

## 2.1.1 - 2018-08-14
### Fixed
*   Fix handling no remote delete of remote directories when using --no-remote-delete
*   Fix handling of no permission to access a local file / corrupt local file
*   Fix application crash when unable to access login.microsoft.com upon application startup
### Added
*   Build instructions for openSUSE Leap 15.0

## 2.1.0 - 2018-08-10
### Fixed
*   Fix handling of database exit scenarios when there is zero disk space left on drive where the items database resides
*   Fix handling of incorrect database permissions
*   Fix handling of different database versions to automatically re-create tables if version mis-match
*   Fix handling timeout when accessing the Microsoft OneDrive Service
*   Fix localFileModifiedTime to not use fraction seconds
### Added
*   Implement Feature: Add a progress bar for large uploads & downloads
*   Implement Feature: Make checkinterval for monitor configurable
*   Implement Feature: Upload Only Option that does not perform remote delete
*   Implement Feature: Add ability to skip symlinks
*   Add dependency, ebuild and build instructions for Gentoo distributions
### Changed
*   Build instructions for x86, x86_64 and ARM32 platforms
*   Travis CI files to automate building on x32, x64 and ARM32 architectures
*   Travis CI files to test built application against valid, invalid and problem files from previous issues

## 2.0.2 - 2018-07-18
### Fixed
*   Fix systemd service install for builds with DESTDIR defined
*   Fix 'HTTP 412 - Precondition Failed' error handling
*   Gracefully handle OneDrive account password change
*   Update logic handling of --upload-only and --local-first

## 2.0.1 - 2018-07-11
### Fixed
*   Resolve computeQuickXorHash generates a different hash when files are > 64Kb

## 2.0.0 - 2018-07-10
### Fixed
*   Resolve conflict resolution issue during syncing - the client does not handle conflicts very well & keeps on adding the hostname to files
*   Resolve skilion #356 by adding additional check for 409 response from OneDrive
*   Resolve multiple versions of file shown on website after single upload
*   Resolve to gracefully fail when 'onedrive' process cannot get exclusive database lock
*   Resolve 'Key not found: fileSystemInfo' when then item is a remote item (OneDrive Personal)
*   Resolve skip_file config entry needs to be checked for any characters to escape
*   Resolve Microsoft Naming Convention not being followed correctly
*   Resolve Error when trying to upload a file with weird non printable characters present
*   Resolve Crash if file is locked by online editing (status code 423)
*   Resolve compilation issue with dmd-2.081.0
*   Resolve skip_file configuration doesn't handle spaces or specified directory paths
### Added
*   Implement Feature: Add a flag to detect when the sync-folder is missing
*   Implement Travis CI for code testing
### Changed
*   Update Makefile to use DESTDIR variables
*   Update OneDrive Business maximum path length from 256 to 400
*   Update OneDrive Business allowed characters for files and folders
*   Update sync_dir handling to use the absolute path for setting parameter to something other than ~/OneDrive via config file or command line
*   Update Fedora build instructions

## 1.1.2 - 2018-05-17
### Fixed
*   Fix 4xx errors including (412 pre-condition, 409 conflict)
*   Fix Key not found: lastModifiedDateTime (OneDrive API change)
*   Fix configuration directory not found when run via init.d
*   Fix skilion Issues #73, #121, #132, #224, #257, #294, #295, #297, #298, #300, #306, #315, #320, #329, #334, #337, #341
### Added
*   Add logging - log client activities to a file (/var/log/onedrive/%username%.onedrive.log or ~/onedrive.log)
*   Add https debugging as a flag
*   Add `--synchronize` to prevent from syncing when just blindly running the application
*   Add individual folder sync
*   Add sync from local directory first rather than download first then upload
*   Add upload long path check
*   Add upload only
*   Add check for max upload file size before attempting upload
*   Add systemd unit files for single & multi user configuration
*   Add init.d file for older init.d based services
*   Add Microsoft naming conventions and namespace validation for items that will be uploaded
*   Add remaining free space counter at client initialisation to avoid out of space upload issue
*   Add large file upload size check to align to OneDrive file size limitations
*   Add upload file size validation & retry if does not match
*   Add graceful handling of some fatal errors (OneDrive 5xx error handling)

## Unreleased - 2018-02-19
### Fixed
*   Crash when the delta link is expired
### Changed
*   Disabled buffering on stdout

## 1.1.1 - 2018-01-20
### Fixed
*   Wrong regex for parsing authentication uri

## 1.1.0 - 2018-01-19
### Added
*   Support for shared folders (OneDrive Personal only)
*   `--download` option to only download changes
*   `DC` variable in Makefile to chose the compiler
### Changed
*   Print logs on stdout instead of stderr
*   Improve log messages

## 1.0.1 - 2017-08-01
### Added
*   `--syncdir` option
### Changed
*   `--version` output simplified
*   Updated README
### Fixed
*   Fix crash caused by remotely deleted and recreated directories

## 1.0.0 - 2017-07-14
### Added
*   `--version` option
