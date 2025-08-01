// What is this module called?
module syncEngine;

// What does this module require to function?
import core.memory;
import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE, exit;
import core.thread;
import core.time;
import std.algorithm;
import std.array;
import std.concurrency;
import std.container.rbtree;
import std.conv;
import std.datetime;
import std.encoding;
import std.exception;
import std.file;
import std.json;
import std.parallelism;
import std.path;
import std.range;
import std.regex;
import std.stdio;
import std.string;
import std.uni;
import std.uri;
import std.utf;
import std.math;

import std.typecons;

// What other modules that we have created do we need to import?
import config;
import log;
import util;
import onedrive;
import itemdb;
import clientSideFiltering;
import xattr;

class JsonResponseException: Exception {
	@safe pure this(string inputMessage) {
		string msg = format(inputMessage);
		super(msg);
	}
}

class PosixException: Exception {
	@safe pure this(string localTargetName, string remoteTargetName) {
		string msg = format("POSIX 'case-insensitive match' between '%s' (local) and '%s' (online) which violates the Microsoft OneDrive API namespace convention", localTargetName, remoteTargetName);
		super(msg);
	}
}

class AccountDetailsException: Exception {
	@safe pure this() {
		string msg = format("Unable to query OneDrive API to obtain required account details");
		super(msg);
	}
}

class SyncException: Exception {
    @nogc @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

struct DriveDetailsCache {
	// - driveId is the drive for the operations were items need to be stored
	// - quotaRestricted details a bool value as to if that drive is restricting our ability to understand if there is space available. Some 'Business' and 'SharePoint' restrict, and most (if not all) shared folders it cant be determined if there is free space
	// - quotaAvailable is a long value that stores the value of what the current free space is available online
	string driveId;
	bool quotaRestricted;
	bool quotaAvailable;
	long quotaRemaining;
}

struct DeltaLinkDetails {
	string driveId;
	string itemId;
	string latestDeltaLink;
}

struct DatabaseItemsToDeleteOnline {
	Item dbItem;
	string localFilePath;
}

class SyncEngine {
	// Class Variables
	ApplicationConfig appConfig;
	ItemDatabase itemDB;
	ClientSideFiltering selectiveSync;
	
	// Array of directory databaseItem.id to skip while applying the changes.
	// These are the 'parent path' id's that are being excluded, so if the parent id is in here, the child needs to be skipped as well
	RedBlackTree!string skippedItems = redBlackTree!string();
	
	// Array consisting of 'item.driveId', 'item.id' and 'item.parentId' values to delete after all the online changes have been downloaded
	string[3][] idsToDelete;
	// Array of JSON items which are files or directories that are not 'root', skipped or to be deleted, that need to be processed
	JSONValue[] jsonItemsToProcess;
	// Array of JSON items which are files that are not 'root', skipped or to be deleted, that need to be downloaded
	JSONValue[] fileJSONItemsToDownload;
	// Array of paths that failed to download
	string[] fileDownloadFailures;
	// Associative array mapping of all OneDrive driveId's that have been seen, mapped with DriveDetailsCache data for reference
	DriveDetailsCache[string] onlineDriveDetails;
	// List of items we fake created when using --dry-run
	string[2][] idsFaked;
	// List of paths we fake deleted when using --dry-run
	string[] pathFakeDeletedArray;
	// Array of database Parent Item ID, Item ID & Local Path where the content has changed and needs to be uploaded
	string[3][] databaseItemsWhereContentHasChanged;
	// Array of local file paths that need to be uploaded as new items to OneDrive
	string[] newLocalFilesToUploadToOneDrive;
	// Array of local file paths that failed to be uploaded to OneDrive
	string[] fileUploadFailures;
	// List of path names changed online, but not changed locally when using --dry-run
	string[] pathsRenamed;
	// List of paths that were a POSIX case-insensitive match, thus could not be created online
	string[] posixViolationPaths;
	// List of local paths, that, when using the OneDrive Business Shared Folders feature, then disabling it, folder still exists locally and online
	// This list of local paths need to be skipped
	string[] businessSharedFoldersOnlineToSkip;
	// List of interrupted uploads session files that need to be resumed
	string[] interruptedUploadsSessionFiles;
	// List of interrupted downloads that need to be resumed
	string[] interruptedDownloadFiles;
	// List of validated interrupted uploads session JSON items to resume
	JSONValue[] jsonItemsToResumeUpload;
	// List of validated interrupted download JSON items to resume
	JSONValue[] jsonItemsToResumeDownload;
	// This list of local paths that need to be created online
	string[] pathsToCreateOnline;
	// Array of items from the database that have been deleted locally, that needs to be deleted online
	DatabaseItemsToDeleteOnline[] databaseItemsToDeleteOnline;
	// Array of parentId's that have been skipped via 'sync_list'
	string[] syncListSkippedParentIds;
	// Array of Microsoft OneNote Notebook Package ID's
	string[] onenotePackageIdentifiers;
		
	// Flag that there were upload or download failures listed
	bool syncFailures = false;
	// Is sync_list configured
	bool syncListConfigured = false;
	// Was --dry-run used?
	bool dryRun = false;
	// Was --upload-only used?
	bool uploadOnly = false;
	// Was --remove-source-files used?
	// Flag to set whether the local file should be deleted once it is successfully uploaded to OneDrive
	bool localDeleteAfterUpload = false;
	
	// Do we configure to disable the download validation routine due to --disable-download-validation
	// We will always validate our downloads
	// However, when downloading files from SharePoint, the OneDrive API will not advise the correct file size 
	// which means that the application thinks the file download has failed as the size is different / hash is different
	// See: https://github.com/abraunegg/onedrive/discussions/1667
    bool disableDownloadValidation = false;
	
	// Do we configure to disable the upload validation routine due to --disable-upload-validation
	// We will always validate our uploads
	// However, when uploading a file that can contain metadata SharePoint will associate some 
	// metadata from the library the file is uploaded to directly in the file which breaks this validation. 
	// See: https://github.com/abraunegg/onedrive/issues/205
	// See: https://github.com/OneDrive/onedrive-api-docs/issues/935
	bool disableUploadValidation = false;
	
	// Do we perform a local cleanup of files that are 'extra' on the local file system, when using --download-only
	bool cleanupLocalFiles = false;
	// Are we performing a --single-directory sync ?
	bool singleDirectoryScope = false;
	string singleDirectoryScopeDriveId;
	string singleDirectoryScopeItemId;
	// Is National Cloud Deployments configured ?
	bool nationalCloudDeployment = false;
	// Do we configure not to perform a remote file delete if --upload-only & --no-remote-delete configured
	bool noRemoteDelete = false;
	// Is bypass_data_preservation set via config file
	// Local data loss MAY occur in this scenario
	bool bypassDataPreservation = false;
	// Has the user configured to permanently delete files online rather than send to online recycle bin
	bool permanentDelete = false;
	// Maximum file size upload
	//  https://support.microsoft.com/en-us/office/invalid-file-names-and-file-types-in-onedrive-and-sharepoint-64883a5d-228e-48f5-b3d2-eb39e07630fa?ui=en-us&rs=en-us&ad=us
	//	July 2020, maximum file size for all accounts is 100GB
	//  January 2021, maximum file size for all accounts is 250GB
	long maxUploadFileSize = 268435456000; // 250GB
	// Threshold after which files will be uploaded using an upload session
	long sessionThresholdFileSize = 4 * 2^^20; // 4 MiB
	// File size limit for file operations that the user has configured
	long fileSizeLimit;
	// Total data to upload
	long totalDataToUpload;
	// How many items have been processed for the active operation
	long processedCount;
	// Are we creating a simulated /delta response? This is critically important in terms of how we 'update' the database
	bool generateSimulatedDeltaResponse = false;
	// Store the latest DeltaLink
	string latestDeltaLink;
	// Struct of containing the deltaLink details
	DeltaLinkDetails deltaLinkCache;
	// Array of driveId and deltaLink for use when performing the last examination of the most recent online data
	alias DeltaLinkInfo = string[string];
	DeltaLinkInfo deltaLinkInfo;
	// Flag to denote data cleanup pass when using --download-only --cleanup-local-files
	bool cleanupDataPass = false;
	// Create the specific task pool to process items in parallel
	TaskPool processPool;
	
	// Shared Folder Flags for 'sync_list' processing
	bool sharedFolderDeltaGeneration = false;
	string currentSharedFolderName = "";
	
	// Directory excluded by 'sync_list flag so that when scanning that directory, if it is excluded, 
	// can be scanned for new data which may be included by other include rule, but parent is excluded
	bool syncListDirExcluded = false;
	
	// Debug Logging Break Lines
	string debugLogBreakType1 = "-----------------------------------------------------------------------------------------------------------";
	string debugLogBreakType2 = "===========================================================================================================";
	
	// Configure this class instance
	this(ApplicationConfig appConfig, ItemDatabase itemDB, ClientSideFiltering selectiveSync) {
	
		// Create the specific task pool to process items in parallel
		processPool = new TaskPool(to!int(appConfig.getValueLong("threads")));
		if (debugLogging) {addLogEntry("Initialised TaskPool worker with threads: " ~ to!string(processPool.size), ["debug"]);}
		
		// Configure the class variable to consume the application configuration
		this.appConfig = appConfig;
		// Configure the class variable to consume the database configuration
		this.itemDB = itemDB;
		// Configure the class variable to consume the selective sync (skip_dir, skip_file and sync_list) configuration
		this.selectiveSync = selectiveSync;
		
		// Configure the dryRun flag to capture if --dry-run was used
		// Application startup already flagged we are also in a --dry-run state, so no need to output anything else here
		this.dryRun = appConfig.getValueBool("dry_run");
		
		// Configure file size limit
		if (appConfig.getValueLong("skip_size") != 0) {
			fileSizeLimit = appConfig.getValueLong("skip_size") * 2^^20;
			fileSizeLimit = (fileSizeLimit == 0) ? long.max : fileSizeLimit;
		}
		
		// Is there a sync_list file present?
		if (exists(appConfig.syncListFilePath)) {
			// yes there is a file present, but did we load any entries?
			if (!selectiveSync.validSyncListRules) {
				// function returned 'false' (array contains valid entries)
				// flag there are rules to process when we are performing Client Side Filtering
				if (debugLogging) {addLogEntry("Configuring syncListConfigured flag to TRUE as valid entries were loaded from 'sync_list' file", ["debug"]);}
				this.syncListConfigured = true;
			} else {
				// function returned 'true' meaning there are are zero sync_list rules loaded despite the 'sync_list' file being present
				// ensure this flag is false so we do not do any extra processing
				if (debugLogging) {addLogEntry("Configuring syncListConfigured flag to FALSE as no valid entries were loaded from 'sync_list' file", ["debug"]);}
				this.syncListConfigured = false;
			}
		}
		
		// Configure the uploadOnly flag to capture if --upload-only was used
		if (appConfig.getValueBool("upload_only")) {
			if (debugLogging) {addLogEntry("Configuring uploadOnly flag to TRUE as --upload-only passed in or configured", ["debug"]);}
			this.uploadOnly = true;
		}
		
		// Configure the localDeleteAfterUpload flag
		if (appConfig.getValueBool("remove_source_files")) {
			if (debugLogging) {addLogEntry("Configuring localDeleteAfterUpload flag to TRUE as --remove-source-files passed in or configured", ["debug"]);}
			this.localDeleteAfterUpload = true;
		}
		
		// Configure the disableDownloadValidation flag
		if (appConfig.getValueBool("disable_download_validation")) {
			if (debugLogging) {addLogEntry("Configuring disableDownloadValidation flag to TRUE as --disable-download-validation passed in or configured", ["debug"]);}
			this.disableDownloadValidation = true;
		}
		
		// Configure the disableUploadValidation flag
		if (appConfig.getValueBool("disable_upload_validation")) {
			if (debugLogging) {addLogEntry("Configuring disableUploadValidation flag to TRUE as --disable-upload-validation passed in or configured", ["debug"]);}
			this.disableUploadValidation = true;
		}
		
		// Do we configure to clean up local files if using --download-only ?
		if ((appConfig.getValueBool("download_only")) && (appConfig.getValueBool("cleanup_local_files"))) {
			// --download-only and --cleanup-local-files were passed in
			addLogEntry();
			addLogEntry("WARNING: Application has been configured to cleanup local files that are not present online.");
			addLogEntry("WARNING: Local data loss MAY occur in this scenario if you are expecting data to remain archived locally.");
			addLogEntry();
			// Set the flag
			this.cleanupLocalFiles = true;
		}
		
		// Do we configure to NOT perform a remote delete if --upload-only & --no-remote-delete configured ?
		if ((appConfig.getValueBool("upload_only")) && (appConfig.getValueBool("no_remote_delete"))) {
			// --upload-only and --no-remote-delete were passed in
			addLogEntry("WARNING: Application has been configured NOT to cleanup remote files that are deleted locally.");
			// Set the flag
			this.noRemoteDelete = true;
		}
		
		// Are we configured to use a National Cloud Deployment?
		if (appConfig.getValueString("azure_ad_endpoint") != "") {
			// value is configured, is it a valid value?
			if ((appConfig.getValueString("azure_ad_endpoint") == "USL4") || (appConfig.getValueString("azure_ad_endpoint") == "USL5") || (appConfig.getValueString("azure_ad_endpoint") == "DE") || (appConfig.getValueString("azure_ad_endpoint") == "CN")) {
				// valid entries to flag we are using a National Cloud Deployment
				// National Cloud Deployments do not support /delta as a query
				// https://docs.microsoft.com/en-us/graph/deployments#supported-features
				// Flag that we have a valid National Cloud Deployment that cannot use /delta queries
				this.nationalCloudDeployment = true;
				// Reverse set 'force_children_scan' for completeness
				appConfig.setValueBool("force_children_scan", true);
			}
		}
		
		// Are we forcing to use /children scan instead of /delta to simulate National Cloud Deployment use of /children?
		if (appConfig.getValueBool("force_children_scan")) {
			addLogEntry("Forcing client to use /children API call rather than /delta API to retrieve objects from the OneDrive API");
			this.nationalCloudDeployment = true;
		}
		
		// Are we forcing the client to bypass any data preservation techniques to NOT rename any local files if there is a conflict?
		// The enabling of this function could lead to data loss
		if (appConfig.getValueBool("bypass_data_preservation")) {
			addLogEntry();
			addLogEntry("WARNING: Application has been configured to bypass local data preservation in the event of file conflict.");
			addLogEntry("WARNING: Local data loss MAY occur in this scenario.");
			addLogEntry();
			this.bypassDataPreservation = true;
		}
		
		// Did the user configure a specific rate limit for the application?
		if (appConfig.getValueLong("rate_limit") > 0) {
			// User configured rate limit
			addLogEntry("User Configured Rate Limit: " ~ to!string(appConfig.getValueLong("rate_limit")));
			
			// If user provided rate limit is < 131072, flag that this is too low, setting to the recommended minimum of 131072
			if (appConfig.getValueLong("rate_limit") < 131072) {
				// user provided limit too low
				addLogEntry("WARNING: User configured rate limit too low for normal application processing and preventing application timeouts. Overriding to recommended minimum of 131072 (128KB/s)");
				appConfig.setValueLong("rate_limit", 131072);
			}
		}
		
		// Did the user downgrade all HTTP operations to force HTTP 1.1
		if (appConfig.getValueBool("force_http_11")) {
			// User is forcing downgrade to curl to use HTTP 1.1 for all operations
			if (verboseLogging) {addLogEntry("Downgrading all HTTP operations to HTTP/1.1 due to user configuration", ["verbose"]);}
		} else {
			// Use curl defaults
			if (debugLogging) {addLogEntry("Using Curl defaults for HTTP operational protocol version (potentially HTTP/2)", ["debug"]);}
		}
	}
	
	// Initialise the Sync Engine class
	bool initialise() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// Control whether the worker threads are daemon threads. A daemon thread is automatically terminated when all non-daemon threads have terminated.
		processPool.isDaemon(true); // daemon thread
		
		// Flag for 'no-sync' task
		bool noSyncTask = false;
		
		// Create a new instance of the OneDrive API
		OneDriveApi oneDriveApiInstance;
		oneDriveApiInstance = new OneDriveApi(appConfig);
		// Exit scope - release curl engine back to pool
		scope(exit) {
			oneDriveApiInstance.releaseCurlEngine();
			// Free object and memory
			oneDriveApiInstance = null;
		}
		
		// Issue #2941
		// If the account being used _only_ has access to specific resources, getDefaultDriveDetails() will generate problems and cause
		// the application to exit, which, is technically the right thing to do (no access to account details) ... but if:
		// - are we doing a no-sync task ?
		// - do we have the 'drive_id' via config file ?
		// Are we not doing a --sync or a --monitor operation? Both of these will be false if they are not set
		if ((!appConfig.getValueBool("synchronize")) && (!appConfig.getValueBool("monitor"))) {
			// set flag
			noSyncTask = true;
		}
		
		// Can the API be initialised successfully?
		if (oneDriveApiInstance.initialise()) {
			// Get the relevant default drive details
			try {
				getDefaultDriveDetails();
			} catch (AccountDetailsException exception) {
				// was this a no-sync task?
				if (!noSyncTask) {
					// details could not be queried
					addLogEntry(exception.msg);
					// Must force exit here, allow logging to be done
					forceExit();
				}
			}
			
			// Get the relevant default root details
			try {
				getDefaultRootDetails();
			} catch (AccountDetailsException exception) {
				// details could not be queried
				addLogEntry(exception.msg);
				// Must force exit here, allow logging to be done
				forceExit();
			}
			
			// Display relevant account details
			try {
				// we only do this if we are doing --verbose logging
				if (verboseLogging) {
					displaySyncEngineDetails();
				}
			} catch (AccountDetailsException exception) {
				// details could not be queried
				addLogEntry(exception.msg);
				// Must force exit here, allow logging to be done
				forceExit();
			}
		} else {
			// API could not be initialised
			addLogEntry("OneDrive API could not be initialised with previously used details");
			// Must force exit here, allow logging to be done
			forceExit();
		}
		
		// Has the client been configured to permanently delete files online rather than send these to the online recycle bin?
		if (appConfig.getValueBool("permanent_delete")) {
			// This can only be set if not using:
			// - US Government L4
			// - US Government L5 (DOD)
			// - Azure and Office365 operated by VNET in China
			// 
			// Additionally, this is not supported by OneDrive Personal accounts:
			//
			//   This is a doc bug. In fact, OneDrive personal accounts do not support the permanentDelete API, it only applies to OneDrive for Business and SharePoint document libraries.
			//
			// Reference: https://learn.microsoft.com/en-us/answers/questions/1501170/onedrive-permanently-delete-a-file
			string azureConfigValue = appConfig.getValueString("azure_ad_endpoint");
			
			// Now that we know the 'accountType' we can configure this correctly
			if ((appConfig.accountType != "personal") && (azureConfigValue.empty || azureConfigValue == "DE")) {
				// Only supported for Global Service and DE based on https://learn.microsoft.com/en-us/graph/api/driveitem-permanentdelete?view=graph-rest-1.0
				addLogEntry();
				addLogEntry("WARNING: Application has been configured to permanently remove files online rather than send to the recycle bin. Permanently deleted items can't be restored.");
				addLogEntry("WARNING: Online data loss MAY occur in this scenario.");
				addLogEntry();
				this.permanentDelete = true;
			} else {
				// what error message do we present
				if (appConfig.accountType == "personal") {
					// personal account type - API not supported
					addLogEntry();
					addLogEntry("WARNING: The application is configured to permanently delete files online; however, this action is not supported by Microsoft OneDrive Personal Accounts.");
					addLogEntry();
				} else {
					// Not a personal account
					addLogEntry();
					addLogEntry("WARNING: The application is configured to permanently delete files online; however, this action is not supported by the National Cloud Deployment in use.");
					addLogEntry();
				}
				// ensure this is false regardless
				this.permanentDelete = false;
			}
		}
		
		// API was initialised
		if (verboseLogging) {addLogEntry("Sync Engine Initialised with new Onedrive API instance", ["verbose"]);}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// return required value
		return true;
	}
	
	// Shutdown the sync engine, wait for anything in processPool to complete
	void shutdown() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}

		if (debugLogging) {addLogEntry("SyncEngine: Waiting for all internal threads to complete", ["debug"]);}
		shutdownProcessPool();
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}	
	}
	
	// Shut down all running tasks that are potentially running in parallel
	void shutdownProcessPool() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// TaskPool needs specific shutdown based on compiler version otherwise this causes a segfault
		if (processPool.size > 0) {
			// TaskPool is still configured for 'thread' size
			// Normal TaskPool shutdown process
			if (debugLogging) {addLogEntry("Shutting down processPool in a thread blocking manner", ["debug"]);}
			// All worker threads are daemon threads which are automatically terminated when all non-daemon threads have terminated.
			processPool.finish(true); // If blocking argument is true, wait for all worker threads to terminate before returning.
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
		
	// Get Default Drive Details for this Account
	void getDefaultDriveDetails() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Function variables
		JSONValue defaultOneDriveDriveDetails;
		bool noSyncTask = false;
		
		// Create a new instance of the OneDrive API
		OneDriveApi getDefaultDriveApiInstance;
		getDefaultDriveApiInstance = new OneDriveApi(appConfig);
		getDefaultDriveApiInstance.initialise();
		
		// Are we not doing a --sync or a --monitor operation? Both of these will be false if they are not set
		if ((!appConfig.getValueBool("synchronize")) && (!appConfig.getValueBool("monitor"))) {
			// set flag
			noSyncTask = true;
		}
		
		// Get Default Drive Details for this Account
		try {
			if (debugLogging) {addLogEntry("Getting Account Default Drive Details", ["debug"]);}
			defaultOneDriveDriveDetails = getDefaultDriveApiInstance.getDefaultDriveDetails();
		} catch (OneDriveException exception) {
			if (debugLogging) {addLogEntry("defaultOneDriveDriveDetails = getDefaultDriveApiInstance.getDefaultDriveDetails() generated a OneDriveException", ["debug"]);}
						
			if ((exception.httpStatusCode == 400) || (exception.httpStatusCode == 401)) {
				// Handle the 400 | 401 error
				handleClientUnauthorised(exception.httpStatusCode, exception.error);
			} else {
				// Default operation if not 400,401 errors
				// - 408,429,503,504 errors are handled as a retry within getDefaultDriveApiInstance
				// Display what the error is
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
			}
		}
		
		// If the JSON response is a correct JSON object, and has an 'id' we can set these details
		if ((defaultOneDriveDriveDetails.type() == JSONType.object) && (hasId(defaultOneDriveDriveDetails))) {
			if (debugLogging) {addLogEntry("OneDrive Account Default Drive Details:      " ~ to!string(defaultOneDriveDriveDetails), ["debug"]);}
			appConfig.accountType = defaultOneDriveDriveDetails["driveType"].str;
			
			// Issue #3115 - Validate driveId length
			// What account type is this?
			if (appConfig.accountType == "personal") {
				// Test driveId length and validation
				// Once checked and validated, we only need to check 'driveId' if it does not match exactly 'appConfig.defaultDriveId'
				appConfig.defaultDriveId = transformToLowerCase(testProvidedDriveIdForLengthIssue(defaultOneDriveDriveDetails["id"].str));
			} else {
				// Use 'defaultOneDriveDriveDetails' as is for all other account types
				appConfig.defaultDriveId = defaultOneDriveDriveDetails["id"].str;
			}
			
			// Make sure that appConfig.defaultDriveId is in our driveIDs array to use when checking if item is in database
			// Keep the DriveDetailsCache array with unique entries only
			DriveDetailsCache cachedOnlineDriveData;
			if (!canFindDriveId(appConfig.defaultDriveId, cachedOnlineDriveData)) {
				// Add this driveId to the drive cache, which then also sets for the defaultDriveId:
				// - quotaRestricted;
				// - quotaAvailable;
				// - quotaRemaining;
				//
				// In some cases OneDrive Business configurations 'restrict' quota details thus is empty / blank / negative value / zero value
				// When addOrUpdateOneDriveOnlineDetails() is called, messaging is provided if these are zero, negative or missing (thus quota is being restricted)
				addOrUpdateOneDriveOnlineDetails(appConfig.defaultDriveId);
			}
			
			// Fetch the details from cachedOnlineDriveData for appConfig.defaultDriveId
			cachedOnlineDriveData = getDriveDetails(appConfig.defaultDriveId);
			// - cachedOnlineDriveData.quotaRestricted;
			// - cachedOnlineDriveData.quotaAvailable;
			// - cachedOnlineDriveData.quotaRemaining;
			
			// What did we set based on the data from the JSON and cached drive data
			if (debugLogging) {
				addLogEntry("appConfig.accountType                 = " ~ appConfig.accountType, ["debug"]);
				addLogEntry("appConfig.defaultDriveId              = " ~ appConfig.defaultDriveId, ["debug"]);
				addLogEntry("cachedOnlineDriveData.quotaRemaining  = " ~ to!string(cachedOnlineDriveData.quotaRemaining), ["debug"]);
				addLogEntry("cachedOnlineDriveData.quotaAvailable  = " ~ to!string(cachedOnlineDriveData.quotaAvailable), ["debug"]);
				addLogEntry("cachedOnlineDriveData.quotaRestricted = " ~ to!string(cachedOnlineDriveData.quotaRestricted), ["debug"]);
			}
			
			// Regardless of this being all set - based on the JSON response, check for 'quota' being present, to check 
			// for the following valid states: normal | nearing | critical | exceeded
			//
			// Based on this, then generate an applicable application message to advise the user of their quota status
			if ((hasQuota(defaultOneDriveDriveDetails)) && (hasQuotaState(defaultOneDriveDriveDetails))) {
				// get the current state
				string quotaState = defaultOneDriveDriveDetails["quota"]["state"].str;
				
				// quotaState = normal - no message
				string nearingMessage = "WARNING: Your Microsoft OneDrive storage is nearing capacity, with less than 10% of your available space remaining.";
				string criticalMessage = "WARNING: Your Microsoft OneDrive storage is critically low, with less than 1% of your available space remaining.";
				string exceededMessage = "CRITICAL: Your Microsoft OneDrive storage limit has been exceeded. You can no longer upload new content to Microsoft OneDrive.";
				string actionRequired = "         Delete unneeded files or upgrade your storage plan now, as further uploads will not be possible once storage is exceeded";
				
				// switch to display the right message
				switch(quotaState) {
					case "nearing":
						addLogEntry();
						addLogEntry(nearingMessage, ["info", "notify"]);
						addLogEntry(actionRequired);
						addLogEntry();
						break;
					case "critical":
						addLogEntry();
						addLogEntry(criticalMessage, ["info", "notify"]);
						addLogEntry(actionRequired);
						addLogEntry();
						break;
					case "exceeded":
						addLogEntry();
						addLogEntry("******************************************************************************************************************************");
						addLogEntry(exceededMessage, ["info", "notify"]);
						addLogEntry("******************************************************************************************************************************");
						addLogEntry();
						break;
					default:
						// nothing
				}
			}
		} else {
			// Did the configuration file contain a 'drive_id' entry
			// If this exists, this will be a 'documentLibrary'
			if (appConfig.getValueString("drive_id").length) {
				// Force set these as for whatever reason we could to query these via the getDefaultDriveDetails API call
				appConfig.accountType = "documentLibrary";
				appConfig.defaultDriveId = appConfig.getValueString("drive_id");
			} else {
				// was this a no-sync task?
				if (!noSyncTask) {
					// Handle the invalid JSON response by throwing an exception error
					throw new AccountDetailsException();
				}
			}
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		getDefaultDriveApiInstance.releaseCurlEngine();
		getDefaultDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Get Default Root Details for this Account
	void getDefaultRootDetails() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Function variables
		JSONValue defaultOneDriveRootDetails;
		bool noSyncTask = false;
		
		// Create a new instance of the OneDrive API
		OneDriveApi getDefaultRootApiInstance;
		getDefaultRootApiInstance = new OneDriveApi(appConfig);
		getDefaultRootApiInstance.initialise();
		
		// Are we not doing a --sync or a --monitor operation? Both of these will be false if they are not set
		if ((!appConfig.getValueBool("synchronize")) && (!appConfig.getValueBool("monitor"))) {
			// set flag
			noSyncTask = true;
		}
		
		// Get Default Root Details for this Account
		try {
			if (debugLogging) {addLogEntry("Getting Account Default Root Details", ["debug"]);}
			defaultOneDriveRootDetails = getDefaultRootApiInstance.getDefaultRootDetails();
		} catch (OneDriveException exception) {
			if (debugLogging) {addLogEntry("defaultOneDriveRootDetails = getDefaultRootApiInstance.getDefaultRootDetails() generated a OneDriveException", ["debug"]);}
			
			if ((exception.httpStatusCode == 400) || (exception.httpStatusCode == 401)) {
				// Handle the 400 | 401 error
				handleClientUnauthorised(exception.httpStatusCode, exception.error);
			} else {
				// Default operation if not 400,401 errors
				// - 408,429,503,504 errors are handled as a retry within getDefaultRootApiInstance
				// Display what the error is
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
			}
		}
		
		// If the JSON response is a correct JSON object, and has an 'id' we can set these details
		if ((defaultOneDriveRootDetails.type() == JSONType.object) && (hasId(defaultOneDriveRootDetails))) {
			// Read the returned JSON data for the root drive details
			if (debugLogging) {addLogEntry("OneDrive Account Default Root Details:       " ~ to!string(defaultOneDriveRootDetails), ["debug"]);}
			appConfig.defaultRootId = defaultOneDriveRootDetails["id"].str;
			if (debugLogging) {addLogEntry("appConfig.defaultRootId      = " ~ appConfig.defaultRootId, ["debug"]);}
			
			// Save the item to the database, so the account root drive is is always going to be present in the DB
			saveItem(defaultOneDriveRootDetails);
		} else {
			// was this a no-sync task?
			if (!noSyncTask) {
				// Handle the invalid JSON response by throwing an exception error
				throw new AccountDetailsException();
			}
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		getDefaultRootApiInstance.releaseCurlEngine();
		getDefaultRootApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Reset syncFailures to false based on file activity
	void resetSyncFailures() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Log initial status and any non-empty arrays
		string logMessage = "Evaluating reset of syncFailures: ";
		if (fileDownloadFailures.length > 0) {
			logMessage ~= "fileDownloadFailures is not empty; ";
		}
		if (fileUploadFailures.length > 0) {
			logMessage ~= "fileUploadFailures is not empty; ";
		}

		// Check if both arrays are empty to reset syncFailures
		if (fileDownloadFailures.length == 0 && fileUploadFailures.length == 0) {
			if (syncFailures) {
				syncFailures = false;
				logMessage ~= "Resetting syncFailures to false.";
			} else {
				logMessage ~= "syncFailures already false.";
			}
		} else {
			// Indicate no reset of syncFailures due to non-empty conditions
			logMessage ~= "Not resetting syncFailures due to non-empty arrays.";
		}

		// Log the final decision and conditions
		if (debugLogging) {addLogEntry(logMessage, ["debug"]);}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Perform a sync of the OneDrive Account
	// - Query /delta
	//		- If singleDirectoryScope or nationalCloudDeployment is used we need to generate a /delta like response
	// - Process changes (add, changes, moves, deletes)
	// - Process any items to add (download data to local)
	// - Detail any files that we failed to download
	// - Process any deletes (remove local data)
	void syncOneDriveAccountToLocalDisk() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// performFullScanTrueUp value
		if (debugLogging) {addLogEntry("Perform a Full Scan True-Up: " ~ to!string(appConfig.fullScanTrueUpRequired), ["debug"]);}
		
		// Fetch the API response of /delta to track changes that were performed online
		fetchOneDriveDeltaAPIResponse();
		
		// Process any download activities or cleanup actions
		processDownloadActivities();
		
		// If singleDirectoryScope is false, we are not targeting a single directory
		// but if true, the target 'could' be a shared folder - so dont try and scan it again
		if (!singleDirectoryScope) {
			// OneDrive Shared Folder Handling
			if (appConfig.accountType == "personal") {
				// Personal Account Type
				// https://github.com/OneDrive/onedrive-api-docs/issues/764
				
				// Get the Remote Items from the Database
				Item[] remoteItems = itemDB.selectRemoteItems();
				foreach (remoteItem; remoteItems) {
					// Check if this path is specifically excluded by 'skip_dir', but only if 'skip_dir' is not empty
					if (appConfig.getValueString("skip_dir") != "") {
						// The path that needs to be checked needs to include the '/'
						// This due to if the user has specified in skip_dir an exclusive path: '/path' - that is what must be matched
						if (selectiveSync.isDirNameExcluded(remoteItem.name)) {
							// This directory name is excluded
							if (verboseLogging) {addLogEntry("Skipping path - excluded by skip_dir config: " ~ remoteItem.name, ["verbose"]);}
							continue;
						}
					}
					
					// Directory name is not excluded or skip_dir is not populated
					if (!appConfig.suppressLoggingOutput) {
						// So that we represent correctly where this shared folder is, calculate the path
						string sharedFolderLogicalPath = computeItemPath(remoteItem.driveId, remoteItem.id);
						addLogEntry("Syncing this OneDrive Personal Shared Folder: " ~ ensureStartsWithDotSlash(sharedFolderLogicalPath));
					}
					// Check this OneDrive Personal Shared Folder for changes
					fetchOneDriveDeltaAPIResponse(remoteItem.remoteDriveId, remoteItem.remoteId, remoteItem.name);
					
					// Process any download activities or cleanup actions for this OneDrive Personal Shared Folder
					processDownloadActivities();
				}
				// Clear the array
				remoteItems = [];
			} else {
				// Is this a Business Account with Sync Business Shared Items enabled?
				if ((appConfig.accountType == "business") && (appConfig.getValueBool("sync_business_shared_items"))) {
				
					// Business Account Shared Items Handling
					// - OneDrive Business Shared Folder
					// - OneDrive Business Shared Files
					// - SharePoint Links
				
					// Get the Remote Items from the Database
					Item[] remoteItems = itemDB.selectRemoteItems();
					
					foreach (remoteItem; remoteItems) {
						// As all remote items are returned, including files, we only want to process directories here
						if (remoteItem.remoteType == ItemType.dir) {
							// Check if this path is specifically excluded by 'skip_dir', but only if 'skip_dir' is not empty
							if (appConfig.getValueString("skip_dir") != "") {
								// The path that needs to be checked needs to include the '/'
								// This due to if the user has specified in skip_dir an exclusive path: '/path' - that is what must be matched
								if (selectiveSync.isDirNameExcluded(remoteItem.name)) {
									// This directory name is excluded
									if (verboseLogging) {addLogEntry("Skipping path - excluded by skip_dir config: " ~ remoteItem.name, ["verbose"]);}
									continue;
								}
							}
							
							// Directory name is not excluded or skip_dir is not populated
							if (!appConfig.suppressLoggingOutput) {
								// So that we represent correctly where this shared folder is, calculate the path
								string sharedFolderLogicalPath = computeItemPath(remoteItem.driveId, remoteItem.id);
								addLogEntry("Syncing this OneDrive Business Shared Folder: " ~ sharedFolderLogicalPath);
							}
							
							// Debug log output
							if (debugLogging) {
								addLogEntry("Fetching /delta API response for:", ["debug"]);
								addLogEntry("    remoteItem.remoteDriveId: " ~ remoteItem.remoteDriveId, ["debug"]);
								addLogEntry("    remoteItem.remoteId:      " ~ remoteItem.remoteId, ["debug"]);
							}
							
							// Check this OneDrive Business Shared Folder for changes
							fetchOneDriveDeltaAPIResponse(remoteItem.remoteDriveId, remoteItem.remoteId, remoteItem.name);
							
							// Process any download activities or cleanup actions for this OneDrive Business Shared Folder
							processDownloadActivities();
						}
					}
					// Clear the array
					remoteItems = [];
					
					// OneDrive Business Shared File Handling - but only if this option is enabled
					if (appConfig.getValueBool("sync_business_shared_files")) {
						// We need to create a 'new' local folder in the 'sync_dir' where these shared files & associated folder structure will reside
						// Whilst these files are synced locally, the entire folder structure will need to be excluded from syncing back to OneDrive
						// But file changes , *if any* , will need to be synced back to the original shared file location
						//  .
						//	├── Files Shared With Me													-> Directory should not be created online | Not Synced
						//	│          └── Display Name (email address) (of Account who shared file)	-> Directory should not be created online | Not Synced
						//	│          │   └── shared file.ext 											-> File synced with original shared file location on remote drive
						//	│          │   └── shared file.ext 											-> File synced with original shared file location on remote drive
						//	│          │   └── ......			 										-> File synced with original shared file location on remote drive
						//	│          └── Display Name (email address) ...
						//	│		└── shared file.ext ....											-> File synced with original shared file location on remote drive
						
						// Does the Local Folder to store the OneDrive Business Shared Files exist?
						if (!exists(appConfig.configuredBusinessSharedFilesDirectoryName)) {
							// Folder does not exist locally and needs to be created
							addLogEntry("Creating the OneDrive Business Shared Files Local Directory: " ~ appConfig.configuredBusinessSharedFilesDirectoryName);
						
							// Local folder does not exist, thus needs to be created
							mkdirRecurse(appConfig.configuredBusinessSharedFilesDirectoryName);
							// As this will not be created online, generate a response so it can be saved to the database
							Item sharedFilesPath = makeItem(createFakeResponse(baseName(appConfig.configuredBusinessSharedFilesDirectoryName)));
							
							// Add DB record to the local database
							if (debugLogging) {addLogEntry("Creating|Updating into local database a DB record for storing OneDrive Business Shared Files: " ~ to!string(sharedFilesPath), ["debug"]);}
							itemDB.upsert(sharedFilesPath);
						} else {
							// Folder exists locally, is the folder in the database? 
							// Query DB for this path
							Item dbRecord;
							if (!itemDB.selectByPath(baseName(appConfig.configuredBusinessSharedFilesDirectoryName), appConfig.defaultDriveId, dbRecord)) {
								// As this will not be created online, generate a response so it can be saved to the database
								Item sharedFilesPath = makeItem(createFakeResponse(baseName(appConfig.configuredBusinessSharedFilesDirectoryName)));
								
								// Add DB record to the local database
								if (debugLogging) {addLogEntry("Creating|Updating into local database a DB record for storing OneDrive Business Shared Files: " ~ to!string(sharedFilesPath), ["debug"]);}
								itemDB.upsert(sharedFilesPath);
							}
						}
						
						// Query for OneDrive Business Shared Files
						if (verboseLogging) {addLogEntry("Checking for any applicable OneDrive Business Shared Files which need to be synced locally", ["verbose"]);}
						queryBusinessSharedObjects();
						
						// Download any OneDrive Business Shared Files
						processDownloadActivities();
					}
				}
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Cleanup arrays when used in --monitor loops
	void cleanupArrays() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Debug what we are doing
		if (debugLogging) {addLogEntry("Cleaning up all internal arrays used when processing data", ["debug"]);}
		
		// Multi Dimensional Arrays
		idsToDelete.length = 0;
		idsFaked.length = 0;
		databaseItemsWhereContentHasChanged.length = 0;
		
		// JSON Items Arrays
		jsonItemsToProcess = [];
		fileJSONItemsToDownload = [];
		jsonItemsToResumeUpload = [];
		jsonItemsToResumeDownload = [];
		
		// String Arrays
		fileDownloadFailures = [];
		pathFakeDeletedArray = [];
		pathsRenamed = [];
		newLocalFilesToUploadToOneDrive = [];
		fileUploadFailures = [];
		posixViolationPaths = [];
		businessSharedFoldersOnlineToSkip = [];
		interruptedUploadsSessionFiles = [];
		interruptedDownloadFiles = [];
		pathsToCreateOnline = [];
		databaseItemsToDeleteOnline = [];
		
		// Perform Garbage Collection on this destroyed curl engine
		GC.collect();
		if (debugLogging) {addLogEntry("Cleaning of internal arrays complete", ["debug"]);}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Configure singleDirectoryScope = true if this function is called
	// By default, singleDirectoryScope = false
	void setSingleDirectoryScope(string normalisedSingleDirectoryPath) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Function variables
		Item searchItem;
		JSONValue onlinePathData;
		
		// Set the main flag
		singleDirectoryScope = true;
		
		// What are we doing?
		addLogEntry("The OneDrive Client was asked to search for this directory online and create it if it's not located: " ~ normalisedSingleDirectoryPath);
		
		// Query the OneDrive API for the specified path online
		// In a --single-directory scenario, we need to traverse the entire path that we are wanting to sync
		// and then check the path element does it exist online, if it does, is it a POSIX match, or if it does not, create the path
		// Once we have searched online, we have the right drive id and item id so that we can downgrade the sync status, then build up 
		// any object items from that location
		// This is because, in a --single-directory scenario, any folder in the entire path tree could be a 'case-insensitive match'
		
		try {
			onlinePathData = queryOneDriveForSpecificPathAndCreateIfMissing(normalisedSingleDirectoryPath, true);
		} catch (PosixException e) {
			displayPosixErrorMessage(e.msg);
			addLogEntry("ERROR: Requested directory to search for and potentially create has a 'case-insensitive match' to an existing directory on Microsoft OneDrive online.");
		}
		
		// Was a valid JSON response provided?
		if (onlinePathData.type() == JSONType.object) {
			// Valid JSON item was returned
			searchItem = makeItem(onlinePathData);
			if (debugLogging) {addLogEntry("searchItem: " ~ to!string(searchItem), ["debug"]);}
			
			// Is this item a potential Shared Folder?
			// Is this JSON a remote object
			if (isItemRemote(onlinePathData)) {
				// Is this a Personal Account Type or has 'sync_business_shared_items' been enabled?
				if ((appConfig.accountType == "personal") || (appConfig.getValueBool("sync_business_shared_items"))) {
					// The path we are seeking is remote to our account drive id
					searchItem.driveId = onlinePathData["remoteItem"]["parentReference"]["driveId"].str;
					searchItem.id = onlinePathData["remoteItem"]["id"].str;
					
					// Issue #3115 - Validate driveId length
					// What account type is this?
					if (appConfig.accountType == "personal") {
						// Issue #3336 - Convert driveId to lowercase before any test
						searchItem.driveId = transformToLowerCase(searchItem.driveId);
						
						// Test driveId length and validation if the driveId we are testing is not equal to appConfig.defaultDriveId
						if (searchItem.driveId != appConfig.defaultDriveId) {
							searchItem.driveId = testProvidedDriveIdForLengthIssue(searchItem.driveId);
						}
					}
					
					// Create a 'root' and 'Shared Folder' DB Tie Records for this JSON object in a consistent manner
					createRequiredSharedFolderDatabaseRecords(onlinePathData);
				} else {
					// This is a shared folder location, but we are not a 'personal' account, and 'sync_business_shared_items' has not been enabled
					addLogEntry();
					addLogEntry("ERROR: The requested --single-directory path to sync is a Shared Folder online and 'sync_business_shared_items' is not enabled");
					addLogEntry();
					forceExit();
				}
			} 
			
			// Set these items so that these can be used as required
			singleDirectoryScopeDriveId = searchItem.driveId;
			singleDirectoryScopeItemId = searchItem.id;
		} else {
			addLogEntry();
			addLogEntry("ERROR: The requested --single-directory path to sync has generated an error. Please correct this error and try again.");
			addLogEntry();
			forceExit();
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Query OneDrive API for /delta changes and iterate through items online
	void fetchOneDriveDeltaAPIResponse(string driveIdToQuery = null, string itemIdToQuery = null, string sharedFolderName = null) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
				
		string deltaLink = null;
		string currentDeltaLink = null;
		string databaseDeltaLink;
		JSONValue deltaChanges;
		long responseBundleCount;
		long jsonItemsReceived = 0;
		
		// Reset jsonItemsToProcess & processedCount
		jsonItemsToProcess = [];
		processedCount = 0;
		
		// Reset generateSimulatedDeltaResponse
		generateSimulatedDeltaResponse = false;
		
		// Reset Shared Folder Flags for 'sync_list' processing
		sharedFolderDeltaGeneration = false;
		currentSharedFolderName = "";
		
		// Was a driveId provided as an input
		if (strip(driveIdToQuery).empty) {
			// No provided driveId to query, use the account default
			driveIdToQuery = appConfig.defaultDriveId;
			if (debugLogging) {
				addLogEntry("driveIdToQuery was empty, setting to appConfig.defaultDriveId", ["debug"]);
				addLogEntry("driveIdToQuery: " ~ driveIdToQuery, ["debug"]);
			}
		}
		
		// Was an itemId provided as an input
		if (strip(itemIdToQuery).empty) {
			// No provided itemId to query, use the account default
			itemIdToQuery = appConfig.defaultRootId;
			if (debugLogging) {
				addLogEntry("itemIdToQuery was empty, setting to appConfig.defaultRootId", ["debug"]);
				addLogEntry("itemIdToQuery: " ~ itemIdToQuery, ["debug"]);
			}
		}
		
		// What OneDrive API query do we use?
		// - Are we running against a National Cloud Deployments that does not support /delta ?
		//   National Cloud Deployments do not support /delta as a query
		//   https://docs.microsoft.com/en-us/graph/deployments#supported-features
		//
		// - Are we performing a --single-directory sync, which will exclude many items online, focusing in on a specific online directory
		// 
		// - Are we performing a --download-only --cleanup-local-files action?
		//   - If we are, and we use a normal /delta query, we get all the local 'deleted' objects as well.
		//   - If the user deletes a folder online, then replaces it online, we download the deletion events and process the new 'upload' via the web interface .. 
		//     the net effect of this, is that the valid local files we want to keep, are actually deleted ...... not desirable
		if ((singleDirectoryScope) || (nationalCloudDeployment) || (cleanupLocalFiles)) {
			// Generate a simulated /delta response so that we correctly capture the current online state, less any 'online' delete and replace activity
			generateSimulatedDeltaResponse = true;
		}
		
		// Shared Folders, by nature of where that path has been shared with us, we cannot use /delta against that path, as this queries the entire 'other persons' drive:
		//    Syncing this OneDrive Business Shared Folder: Sub Folder 2
		//    Fetching /delta response from the OneDrive API for Drive ID: b!fZgJhK-pU0eTQpylvmoYCkE4YgH_KRNDlxjRx9OWNqmV9Q_E_uWdRJKIB5L_ruPN
		//    Processing API Response Bundle: 1 - Quantity of 'changes|items' in this bundle to process: 18
		//    Skipping path - excluded by sync_list config: Sub Folder Share/Sub Folder 1/Sub Folder 2
		//
		// When using 'sync_list' potentially nothing is going to match, as, we are getting the 'whole' path from their 'root' , not just the folder shared with us
		if (!sharedFolderName.empty) {
			// When using 'sync_list' we need to do this
			sharedFolderDeltaGeneration = true;
			currentSharedFolderName = sharedFolderName;
			generateSimulatedDeltaResponse = true;
		}
		
		// Reset latestDeltaLink & deltaLinkCache
		latestDeltaLink = null;
		deltaLinkCache.driveId = null;
		deltaLinkCache.itemId = null;
		deltaLinkCache.latestDeltaLink = null;
		// Perform Garbage Collection
		GC.collect();
				
		// What /delta query do we use?
		if (!generateSimulatedDeltaResponse) {
			// This should be the majority default pathway application use
			
			// Do we need to perform a Full Scan True Up? Is 'appConfig.fullScanTrueUpRequired' set to 'true'?
			if (appConfig.fullScanTrueUpRequired) {
				addLogEntry("Performing a full scan of online data to ensure consistent local state");
				if (debugLogging) {addLogEntry("Setting currentDeltaLink = null", ["debug"]);}
				currentDeltaLink = null;
			} else {
				// Try and get the current Delta Link from the internal cache, this saves a DB I/O call
				currentDeltaLink = getDeltaLinkFromCache(deltaLinkInfo, driveIdToQuery);
				
				// Is currentDeltaLink empty (no cached entry found) ?
				if (currentDeltaLink.empty) {
					// Try and get the current delta link from the database for this DriveID and RootID
					databaseDeltaLink = itemDB.getDeltaLink(driveIdToQuery, itemIdToQuery);
					if (!databaseDeltaLink.empty) {
						if (debugLogging) {addLogEntry("Using database stored deltaLink", ["debug"]);}
						currentDeltaLink = databaseDeltaLink;
					} else {
						if (debugLogging) {addLogEntry("Zero deltaLink available for use, we will be performing a full online scan", ["debug"]);}
						currentDeltaLink = null;
					}
				} else {
					// Log that we are using the deltaLink for cache
					if (debugLogging) {addLogEntry("Using cached deltaLink", ["debug"]);}
				}
			}
			
			// Dynamic output for non-verbose and verbose run so that the user knows something is being retrieved from the OneDrive API
			if (appConfig.verbosityCount == 0) {
				if (!appConfig.suppressLoggingOutput) {
					addProcessingLogHeaderEntry("Fetching items from the OneDrive API for Drive ID: " ~ driveIdToQuery, appConfig.verbosityCount);
				}
			} else {
				if (verboseLogging) {addLogEntry("Fetching /delta response from the OneDrive API for Drive ID: " ~  driveIdToQuery, ["verbose"]);}
			}
			
			// Create a new API Instance for querying the actual /delta and initialise it
			OneDriveApi getDeltaDataOneDriveApiInstance;
			getDeltaDataOneDriveApiInstance = new OneDriveApi(appConfig);
			getDeltaDataOneDriveApiInstance.initialise();

			// Get the /delta changes via the OneDrive API
			while (true) {
				// Check if exitHandlerTriggered is true
				if (exitHandlerTriggered) {
					// break out of the 'while (true)' loop
					break;
				}
				
				// Increment responseBundleCount
				responseBundleCount++;
				
				// Ensure deltaChanges is empty before we query /delta
				deltaChanges = null;
				// Perform Garbage Collection
				GC.collect();
				
				// getDeltaChangesByItemId has the re-try logic for transient errors
				deltaChanges = getDeltaChangesByItemId(driveIdToQuery, itemIdToQuery, currentDeltaLink, getDeltaDataOneDriveApiInstance);
				
				// If the initial deltaChanges response is an invalid JSON object, keep trying until we get a valid response ..
				if (deltaChanges.type() != JSONType.object) {
					// While the response is not a JSON Object or the Exit Handler has not been triggered
					while (deltaChanges.type() != JSONType.object) {
						// Check if exitHandlerTriggered is true
						if (exitHandlerTriggered) {
							// break out of the 'while (true)' loop
							break;
						}
					
						// Handle the invalid JSON response and retry
						if (debugLogging) {addLogEntry("ERROR: Query of the OneDrive API via deltaChanges = getDeltaChangesByItemId() returned an invalid JSON response", ["debug"]);}
						deltaChanges = getDeltaChangesByItemId(driveIdToQuery, itemIdToQuery, currentDeltaLink, getDeltaDataOneDriveApiInstance);
					}
				}
				
				long nrChanges = count(deltaChanges["value"].array);
				int changeCount = 0;
				
				if (appConfig.verbosityCount == 0) {
					// Dynamic output for a non-verbose run so that the user knows something is happening
					if (!appConfig.suppressLoggingOutput) {
						addProcessingDotEntry();
					}
				} else {
					if (verboseLogging) {addLogEntry("Processing API Response Bundle: " ~ to!string(responseBundleCount) ~ " - Quantity of 'changes|items' in this bundle to process: " ~ to!string(nrChanges), ["verbose"]);}
				}
				
				// Update the count of items received
				jsonItemsReceived = jsonItemsReceived + nrChanges;
				
				// The 'deltaChanges' response may contain either @odata.nextLink or @odata.deltaLink
				// Check for @odata.nextLink
				if ("@odata.nextLink" in deltaChanges) {
					// @odata.nextLink is the pointer within the API to the next '200+' JSON bundle - this is the checkpoint link for this bundle
					// This URL changes between JSON bundle sets
					// Log the action of setting currentDeltaLink to @odata.nextLink
					if (debugLogging) {addLogEntry("Setting currentDeltaLink to @odata.nextLink: " ~ deltaChanges["@odata.nextLink"].str, ["debug"]);}
					
					// Update currentDeltaLink to @odata.nextLink for the next '200+' JSON bundle - this is the checkpoint link for this bundle
					currentDeltaLink = deltaChanges["@odata.nextLink"].str;
				}
				
				// Check for @odata.deltaLink - usually only in the LAST JSON changeset bundle
				if ("@odata.deltaLink" in deltaChanges) {
					// @odata.deltaLink is the pointer that finalises all the online 'changes' for this particular checkpoint
					// When the API is queried again, this is fetched from the DB as this is the starting point
					// The API issue here is - the LAST JSON bundle will ONLY ever contain this item, meaning if this is then committed to the database
					// if there has been any file download failures from within this LAST JSON bundle, the only way to EVER re-try the failed items is for the user to perform a --resync
					// This is an API capability gap:
					//
					// ..
					// @odata.nextLink:  https://graph.microsoft.com/v1.0/drives/<redacted>/items/<redacted>/delta?token=<redacted>
					// Processing API Response Bundle: 115 - Quantity of 'changes|items' in this bundle to process: 204
					// ..
					// @odata.nextLink:  https://graph.microsoft.com/v1.0/drives/<redacted>/items/<redacted>/delta?token=<redacted>
					// Processing API Response Bundle: 127 - Quantity of 'changes|items' in this bundle to process: 204
					// @odata.nextLink:  https://graph.microsoft.com/v1.0/drives/<redacted>/items/<redacted>/delta?token=<redacted>
					// Processing API Response Bundle: 128 - Quantity of 'changes|items' in this bundle to process: 176
					// @odata.deltaLink: https://graph.microsoft.com/v1.0/drives/<redacted>/items/<redacted>/delta?token=<redacted>
					// Finished processing /delta JSON response from the OneDrive API
					
					// Log the action of setting currentDeltaLink to @odata.deltaLink
					if (debugLogging) {addLogEntry("Setting currentDeltaLink to (@odata.deltaLink): " ~ deltaChanges["@odata.deltaLink"].str, ["debug"]);}
					
					// Update currentDeltaLink to @odata.deltaLink as the final checkpoint URL for this entire JSON response set
					currentDeltaLink = deltaChanges["@odata.deltaLink"].str;
					
					// Store this currentDeltaLink as latestDeltaLink
					latestDeltaLink = deltaChanges["@odata.deltaLink"].str;
					
					// Issue #3115 - Validate driveId length
					// What account type is this?
					if (appConfig.accountType == "personal") {
						// Issue #3336 - Convert driveId to lowercase before any test
						driveIdToQuery = transformToLowerCase(driveIdToQuery);
						
						// Test driveId length and validation if the driveId we are testing is not equal to appConfig.defaultDriveId
						if (driveIdToQuery != appConfig.defaultDriveId) {
							driveIdToQuery = testProvidedDriveIdForLengthIssue(driveIdToQuery);
						}
					}
					
					// Update deltaLinkCache
					deltaLinkCache.driveId = driveIdToQuery;
					deltaLinkCache.itemId = itemIdToQuery;
					deltaLinkCache.latestDeltaLink = currentDeltaLink;
				}
				
				// We have a valid deltaChanges JSON array. This means we have at least 200+ JSON items to process.
				// The API response however cannot be run in parallel as the OneDrive API sends the JSON items in the order in which they must be processed
				auto jsonArrayToProcess = deltaChanges["value"].array;
				
				// To allow for better debugging, what are all the JSON elements in the array the API responded with in this set?
				if (count(jsonArrayToProcess) > 0) {
					if (debugLogging) {
						string debugLogHeader = format("=============================== jsonArrayToProcess - response bundle %s ===================================", to!string(responseBundleCount));
						addLogEntry(debugLogHeader, ["debug"]);
						addLogEntry(to!string(jsonArrayToProcess), ["debug"]);
						addLogEntry(debugLogBreakType2, ["debug"]);
					}
				}
				
				// Process the change set
				foreach (onedriveJSONItem; jsonArrayToProcess) {
					// increment change count for this item
					changeCount++;
					// Process the received OneDrive object item JSON for this JSON bundle
					// This will determine its initial applicability and perform some initial processing on the JSON if required
					processDeltaJSONItem(onedriveJSONItem, nrChanges, changeCount, responseBundleCount, singleDirectoryScope);
				}
				
				// Clear up this data
				jsonArrayToProcess = null;
				// Perform Garbage Collection
				GC.collect();
				
				// Is latestDeltaLink matching deltaChanges["@odata.deltaLink"].str ?
				if ("@odata.deltaLink" in deltaChanges) {
					if (latestDeltaLink == deltaChanges["@odata.deltaLink"].str) {
						// break out of the 'while (true)' loop
						break;
					}
				}
				
				// Cleanup deltaChanges as this is no longer needed
				deltaChanges = null;
				// Perform Garbage Collection
				GC.collect();
				
				// Sleep for a while to avoid busy-waiting
				Thread.sleep(dur!"msecs"(100)); // Adjust the sleep duration as needed
			}
			
			// Terminate getDeltaDataOneDriveApiInstance here
			getDeltaDataOneDriveApiInstance.releaseCurlEngine();
			getDeltaDataOneDriveApiInstance = null;
			// Perform Garbage Collection on this destroyed curl engine
			GC.collect();
			
			// To finish off the JSON processing items, this is needed to reflect this in the log
			if (debugLogging) {addLogEntry(debugLogBreakType1, ["debug"]);}
			
			// Log that we have finished querying the /delta API
			if (appConfig.verbosityCount == 0) {
				if (!appConfig.suppressLoggingOutput) {
					// Close out the '....' being printed to the console
					completeProcessingDots();
				}
			} else {
				if (verboseLogging) {addLogEntry("Finished processing /delta JSON response from the OneDrive API", ["verbose"]);}
			}
			
			// If this was set, now unset it, as this will have been completed, so that for a true up, we dont do a double full scan
			if (appConfig.fullScanTrueUpRequired) {
				if (debugLogging) {addLogEntry("Unsetting fullScanTrueUpRequired as this has been performed", ["debug"]);}
				appConfig.fullScanTrueUpRequired = false;
			}
			
			// Cleanup deltaChanges as this is no longer needed
			deltaChanges = null;
			// Perform Garbage Collection
			GC.collect();
		} else {
			// Why are we generating a /delta response
			if (debugLogging) {
				addLogEntry("Why are we generating a /delta response:", ["debug"]);
				addLogEntry(" singleDirectoryScope:    " ~ to!string(singleDirectoryScope), ["debug"]);
				addLogEntry(" nationalCloudDeployment: " ~ to!string(nationalCloudDeployment), ["debug"]);
				addLogEntry(" cleanupLocalFiles:       " ~ to!string(cleanupLocalFiles), ["debug"]);
				addLogEntry(" sharedFolderName:        " ~ sharedFolderName, ["debug"]);
			}
			
			// What 'path' are we going to start generating the response for
			string pathToQuery;
			
			// If --single-directory has been called, use the value that has been set
			if (singleDirectoryScope) {
				pathToQuery = appConfig.getValueString("single_directory");
			}
			
			// We could also be syncing a Shared Folder of some description - is this empty?
			if (!sharedFolderName.empty) {
				// We need to build 'pathToQuery' to support Shared Folders being anywhere in the directory structure (#2824)
				// Is the itemIdToQuery in the database? If this is not there, we cannot build the path
				if (itemDB.idInLocalDatabase(driveIdToQuery, itemIdToQuery)) {
					// The entries are in our DB, but we need to use our Drive details to compute the actual local path the the point of the 'remote' record and DB Tie Record
					Item remoteEntryItem;
					itemDB.selectByRemoteEntryByName(sharedFolderName, remoteEntryItem);
					
					// Use the 'remote' item type DB entry to calculate the local path of this item, which then will match the path online for this Shared Folder
					string computedLocalPathToQuery = computeItemPath(remoteEntryItem.driveId, remoteEntryItem.id);
					// If we have a computed path, use it, else use 'sharedFolderName'
					if (!computedLocalPathToQuery.empty) {
						// computedLocalPathToQuery is not empty
						pathToQuery = computedLocalPathToQuery;	
					} else {
						// computedLocalPathToQuery is empty
						pathToQuery = sharedFolderName;
					}
				} else {
					// shared folder details are not even in the database ... fall back to this
					pathToQuery = sharedFolderName;
				}
				// At this point we have either calculated the shared folder path, or not and can attempt to generate a /delta response from that path entry online
			}
			
			// Generate the simulated /delta response
			//
			// The generated /delta response however contains zero deleted JSON items, so the only way that we can track this, is if the object was in sync
			// we have the object in the database, thus, what we need to do is for every DB object in the tree of items, flag 'syncStatus' as 'N', then when we process 
			// the returned JSON items from the API, we flag the item as back in sync, then we can cleanup any out-of-sync items
			//
			// The flagging of the local database items to 'N' is handled within the generateDeltaResponse() function
			//
			// When these JSON items are then processed, if the item exists online, and is in the DB, and that the values match, the DB item is flipped back to 'Y' 
			// This then allows the application to look for any remaining 'N' values, and delete these as no longer needed locally
			deltaChanges = generateDeltaResponse(pathToQuery);
			
			// deltaChanges must be a valid JSON object / array of data
			if (deltaChanges.type() == JSONType.object) {
				// How many changes were returned?
				long nrChanges = count(deltaChanges["value"].array);
				int changeCount = 0;
				if (debugLogging) {addLogEntry("API Response Bundle: " ~ to!string(responseBundleCount) ~ " - Quantity of 'changes|items' in this bundle to process: " ~ to!string(nrChanges), ["debug"]);}
				// Update the count of items received
				jsonItemsReceived = jsonItemsReceived + nrChanges;
				
				// The API response however cannot be run in parallel as the OneDrive API sends the JSON items in the order in which they must be processed
				auto jsonArrayToProcess = deltaChanges["value"].array;
				foreach (onedriveJSONItem; deltaChanges["value"].array) {
					// increment change count for this item
					changeCount++;
					// Process the received OneDrive object item JSON for this JSON bundle
					// When we generate a /delta response .. there is no currentDeltaLink value
					processDeltaJSONItem(onedriveJSONItem, nrChanges, changeCount, responseBundleCount, singleDirectoryScope);
				}
				
				// Clear up this data
				jsonArrayToProcess = null;
				
				// To finish off the JSON processing items, this is needed to reflect this in the log
				if (debugLogging) {addLogEntry(debugLogBreakType1, ["debug"]);}
			
				// Log that we have finished generating our self generated /delta response
				if (!appConfig.suppressLoggingOutput) {
					addLogEntry("Finished processing self generated /delta JSON response from the OneDrive API");
				}
			}
			
			// Cleanup deltaChanges as this is no longer needed
			deltaChanges = null;
			
			// Perform Garbage Collection
			GC.collect();
		}
		
		// Cleanup deltaChanges as this is no longer needed
		deltaChanges = null;
		// Perform Garbage Collection
		GC.collect();
		
		// We have JSON items received from the OneDrive API
		if (debugLogging) {
			addLogEntry("Number of JSON Objects received from OneDrive API:                 " ~ to!string(jsonItemsReceived), ["debug"]);
			addLogEntry("Number of JSON Objects already processed (root and deleted items): " ~ to!string((jsonItemsReceived - jsonItemsToProcess.length)), ["debug"]);
			// We should have now at least processed all the JSON items as returned by the /delta call
			// Additionally, we should have a new array, that now contains all the JSON items we need to process that are non 'root' or deleted items
			addLogEntry("Number of JSON items submitted for further processing is: " ~ to!string(jsonItemsToProcess.length), ["debug"]);
		}
		
		// Are there items to process?
		if (jsonItemsToProcess.length > 0) {
			// Lets deal with the JSON items in a batch process
			size_t batchSize = 500;
			long batchCount = (jsonItemsToProcess.length + batchSize - 1) / batchSize;
			long batchesProcessed = 0;
			
			// Dynamic output for a non-verbose run so that the user knows something is happening
			if (!appConfig.suppressLoggingOutput) {
				addProcessingLogHeaderEntry("Processing " ~ to!string(jsonItemsToProcess.length) ~ " applicable JSON items received from Microsoft OneDrive", appConfig.verbosityCount);
			}
			
			// For each batch, process the JSON items that need to be now processed.
			// 'root' and deleted objects have already been handled
			foreach (batchOfJSONItems; jsonItemsToProcess.chunks(batchSize)) {
				// Chunk the total items to process into 500 lot items
				batchesProcessed++;
				if (appConfig.verbosityCount == 0) {
					// Dynamic output for a non-verbose run so that the user knows something is happening
					if (!appConfig.suppressLoggingOutput) {
						addProcessingDotEntry();
					}
				} else {
					if (verboseLogging) {addLogEntry("Processing OneDrive JSON item batch [" ~ to!string(batchesProcessed) ~ "/" ~ to!string(batchCount) ~ "] to ensure consistent local state", ["verbose"]);}
				}	
					
				// Process the batch
				processJSONItemsInBatch(batchOfJSONItems, batchesProcessed, batchCount);
				
				// To finish off the JSON processing items, this is needed to reflect this in the log
				if (debugLogging) {addLogEntry(debugLogBreakType1, ["debug"]);}
				
				// For this set of items, perform a DB PASSIVE checkpoint
				itemDB.performCheckpoint("PASSIVE");
			}
			
			if (appConfig.verbosityCount == 0) {
				// close off '.' output
				if (!appConfig.suppressLoggingOutput) {
					// Close out the '....' being printed to the console
					completeProcessingDots();
				}
			}
			
			// Debug output - what was processed
			if (debugLogging) {
				addLogEntry("Number of JSON items to process is: " ~ to!string(jsonItemsToProcess.length), ["debug"]);
				addLogEntry("Number of JSON items processed was: " ~ to!string(processedCount), ["debug"]);
			}
			
			// Notification to user regarding number of objects received from OneDrive API
			if (jsonItemsReceived >= 300000) {
				// 'driveIdToQuery' should be the drive where the JSON responses came from
				string objectsExceedLimitWarning = format("WARNING: The number of objects stored online in '%s' exceeds Microsoft OneDrive's recommended limit. This may cause unreliable application behaviour due to inconsistent or incomplete API responses. Immediate action is strongly advised to avoid data integrity issues.", driveIdToQuery);
				addLogEntry(objectsExceedLimitWarning, ["info", "notify"]);
			}
			
			// Free up memory and items processed as it is pointless now having this data around
			jsonItemsToProcess = [];
			
			// Perform Garbage Collection on this destroyed curl engine
			GC.collect();
		} else {
			if (!appConfig.suppressLoggingOutput) {
				addLogEntry("No changes or items that can be applied were discovered while processing the data received from Microsoft OneDrive");
			}
		}
		
		// Keep the DriveDetailsCache array with unique entries only
		DriveDetailsCache cachedOnlineDriveData;
		if (!canFindDriveId(driveIdToQuery, cachedOnlineDriveData)) {
			// Add this driveId to the drive cache
			addOrUpdateOneDriveOnlineDetails(driveIdToQuery);
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Process the /delta API JSON response items
	void processDeltaJSONItem(JSONValue onedriveJSONItem, long nrChanges, int changeCount, long responseBundleCount, bool singleDirectoryScope) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Variables for this JSON item
		string thisItemId;
		bool itemIsRoot = false;
		bool handleItemAsRootObject = false;
		bool itemIsDeletedOnline = false;
		bool itemHasParentReferenceId = false;
		bool itemHasParentReferencePath = false;
		bool itemIdMatchesDefaultRootId = false;
		bool itemNameExplicitMatchRoot = false;
		bool itemIsRemoteItem = false;
		string objectParentDriveId;
		string objectParentId;
		MonoTime jsonProcessingStartTime;
		
		// Debugging the processing start of the JSON item
		if (debugLogging) {
			addLogEntry(debugLogBreakType1, ["debug"]);
			jsonProcessingStartTime = MonoTime.currTime();
			addLogEntry("Processing OneDrive Item " ~ to!string(changeCount) ~ " of " ~ to!string(nrChanges) ~ " from API Response Bundle " ~ to!string(responseBundleCount), ["debug"]);
		}
		
		// Issue #3336 - Convert driveId to lowercase
		if (appConfig.accountType == "personal") {
			// We must massage this raw JSON record to force the onedriveJSONItem["parentReference"]["driveId"] to lowercase
			if (hasParentReferenceDriveId(onedriveJSONItem)) {
				// This JSON record has a driveId we now must manipulate to lowercase
				string originalDriveIdValue = onedriveJSONItem["parentReference"]["driveId"].str;
				onedriveJSONItem["parentReference"]["driveId"] = transformToLowerCase(originalDriveIdValue);
			}
		}
		
		// Debug output of the raw JSON item we are processing
		if (debugLogging) {
			addLogEntry("Raw JSON OneDrive Item: " ~ sanitiseJSONItem(onedriveJSONItem), ["debug"]);
		}
				
		// What is this item's id
		thisItemId = onedriveJSONItem["id"].str;
		
		// Is this a deleted item - only calculate this once
		itemIsDeletedOnline = isItemDeleted(onedriveJSONItem);
		if (!itemIsDeletedOnline) {
			// This is not a deleted item
			if (debugLogging) {addLogEntry("This item is not a OneDrive online deletion change", ["debug"]);}
			
			// Only calculate this once
			itemIsRoot = isItemRoot(onedriveJSONItem);
			itemHasParentReferenceId = hasParentReferenceId(onedriveJSONItem);
			itemIdMatchesDefaultRootId = (thisItemId == appConfig.defaultRootId);
			itemNameExplicitMatchRoot = (onedriveJSONItem["name"].str == "root");
			objectParentDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
			if (itemHasParentReferenceId) {
				objectParentId = onedriveJSONItem["parentReference"]["id"].str;
			}
			itemIsRemoteItem  = isItemRemote(onedriveJSONItem);
			
			// Test is this is the OneDrive Users Root?
			// Debug output of change evaluation items
			if (debugLogging) {
				addLogEntry("defaultRootId                                        = " ~ appConfig.defaultRootId, ["debug"]);
				addLogEntry("thisItemName                                         = " ~ onedriveJSONItem["name"].str, ["debug"]);
				addLogEntry("thisItemId                                           = " ~ thisItemId, ["debug"]);
				addLogEntry("thisItemId == defaultRootId                          = " ~ to!string(itemIdMatchesDefaultRootId), ["debug"]);
				addLogEntry("isItemRoot(onedriveJSONItem)                         = " ~ to!string(itemIsRoot), ["debug"]);
				addLogEntry("onedriveJSONItem['name'].str == 'root'               = " ~ to!string(itemNameExplicitMatchRoot), ["debug"]);
				addLogEntry("itemHasParentReferenceId                             = " ~ to!string(itemHasParentReferenceId), ["debug"]);
				addLogEntry("itemIsRemoteItem                                     = " ~ to!string(itemIsRemoteItem), ["debug"]);
			}
			
			if ( (itemIdMatchesDefaultRootId || singleDirectoryScope) && itemIsRoot && itemNameExplicitMatchRoot) {
				// This IS a OneDrive Root item or should be classified as such in the case of 'singleDirectoryScope'
				if (debugLogging) {addLogEntry("JSON item will flagged as a 'root' item", ["debug"]);}
				handleItemAsRootObject = true;
			}
		}
		
		// How do we handle this JSON item from the OneDrive API?
		// Is this a confirmed 'root' item, has no Parent ID, or is a Deleted Item
		if (handleItemAsRootObject || !itemHasParentReferenceId || itemIsDeletedOnline){
			// Is a root item, has no id in parentReference or is a OneDrive deleted item
			if (debugLogging) {
				addLogEntry("objectParentDriveId                                  = " ~ objectParentDriveId, ["debug"]);
				addLogEntry("handleItemAsRootObject                               = " ~ to!string(handleItemAsRootObject), ["debug"]);
				addLogEntry("itemHasParentReferenceId                             = " ~ to!string(itemHasParentReferenceId), ["debug"]);
				addLogEntry("itemIsDeletedOnline                                  = " ~ to!string(itemIsDeletedOnline), ["debug"]);
				addLogEntry("Handling change immediately as 'root item', or has no parent reference id or is a deleted item", ["debug"]);
			}
			
			// OK ... do something with this JSON post here ....
			processRootAndDeletedJSONItems(onedriveJSONItem, objectParentDriveId, handleItemAsRootObject, itemIsDeletedOnline, itemHasParentReferenceId);
		} else {
			// Do we need to update this RAW JSON from OneDrive?
			
			bool sharedFolderRenameCheck = false;
			
			// What account type is this?
			if (appConfig.accountType == "personal") {
				// flag this by default as we always sync personal shared folders by default
				sharedFolderRenameCheck = true;
			} else {
				// business | DocumentLibrary
				if (appConfig.getValueBool("sync_business_shared_items")) {
					// flag this
					sharedFolderRenameCheck = true;
				}
			}
			
			// Issue #3336 - Convert driveId to lowercase before any test
			if (appConfig.accountType == "personal") {
				objectParentDriveId = transformToLowerCase(objectParentDriveId);
			}
			
			// Do we check if this JSON needs updating?
			if ((objectParentDriveId != appConfig.defaultDriveId) && (sharedFolderRenameCheck)) {
				// Potentially need to update this JSON data
				if (debugLogging) {addLogEntry("Potentially need to update this source JSON .... need to check the database", ["debug"]);}
				
				// Check the DB for 'remote' objects, searching 'remoteDriveId' and 'remoteId' items for this remoteItem.driveId and remoteItem.id
				Item remoteDBItem;
				itemDB.selectByRemoteId(objectParentDriveId, thisItemId, remoteDBItem);
				
				// Is the data that was returned from the database what we are looking for?
				if ((remoteDBItem.remoteDriveId == objectParentDriveId) && (remoteDBItem.remoteId == thisItemId)) {
					// Yes, this is the record we are looking for
					if (debugLogging) {addLogEntry("DB Item response for remoteDBItem: " ~ to!string(remoteDBItem), ["debug"]);}
				
					// Must compare remoteDBItem.name with remoteItem.name
					if (remoteDBItem.name != onedriveJSONItem["name"].str) {
						// Update JSON Item
						string actualOnlineName = onedriveJSONItem["name"].str;
						if (debugLogging) {
							addLogEntry("Updating source JSON 'name' to that which is the actual local directory", ["debug"]);
							addLogEntry("onedriveJSONItem['name'] was:         " ~ onedriveJSONItem["name"].str, ["debug"]);
							addLogEntry("Updating onedriveJSONItem['name'] to: " ~ remoteDBItem.name, ["debug"]);
						}
						onedriveJSONItem["name"] = remoteDBItem.name;
						if (debugLogging) {addLogEntry("onedriveJSONItem['name'] now:         " ~ onedriveJSONItem["name"].str, ["debug"]);}
						// Add the original name to the JSON
						onedriveJSONItem["actualOnlineName"] = actualOnlineName;
					}
				}
			}
			
			// Do we discard this JSON item?
			bool discardDeltaJSONItem = false;
			
			// Microsoft OneNote container objects present neither folder or file but contain a 'package' element
			// "package": {
			//			"type": "oneNote"
			//		},
			// Confirmed with Microsoft OneDrive Personal
			// Confirmed with Microsoft OneDrive Business
			if (isOneNotePackageFolder(onedriveJSONItem)) {
				// This JSON has this element
				if (verboseLogging) {addLogEntry("Skipping path - The Microsoft OneNote Notebook Package '" ~ generatePathFromJSONData(onedriveJSONItem) ~ "' is not supported by this client", ["verbose"]);}
				discardDeltaJSONItem = true;
				
				// Add this 'id' to onenotePackageIdentifiers as a future 'catch all' for any objects inside this container
				if (!onenotePackageIdentifiers.canFind(thisItemId)) {
					if (debugLogging) {addLogEntry("Adding 'thisItemId' to onenotePackageIdentifiers: " ~ to!string(thisItemId), ["debug"]);}
					onenotePackageIdentifiers ~= thisItemId;
				}
				
			}
			
			// Microsoft OneDrive OneNote file objects will report as files but have 'application/msonenote' or 'application/octet-stream' as their mime type and will not have any hash entry
			// Is there a 'file' JSON element and it has a 'mimeType' element?
			if (isItemFile(onedriveJSONItem) && hasMimeType(onedriveJSONItem)) {
				// Is the mimeType 'application/msonenote' or 'application/octet-stream'
				
				// However there is API inconsistency here between Personal and Business Accounts
				// Personal OneNote .onetoc2 and .one items all report mimeType as 'application/msonenote'
				// Business OneNote .onetoc2 and .one items however are different:
				//  .one = 'application/msonenote' mimeType
				//  .onetoc2 = 'application/octet-stream' mimeType
				if (isMicrosoftOneNoteMimeType1(onedriveJSONItem) || isMicrosoftOneNoteMimeType2(onedriveJSONItem)) {
					// We have a 'mimeType' match
					// What is the file extension?
					// .one (Type1)
					// .onetoc2 (Type2)
					if (isMicrosoftOneNoteFileExtensionType1(onedriveJSONItem) || isMicrosoftOneNoteFileExtensionType2(onedriveJSONItem)) {
						// Extreme confidence this JSON is a Microsoft OneNote file reference which cannot be supported
						// Log that this will be skipped as this this is a Microsoft OneNote item and unsupported
						if (verboseLogging) {addLogEntry("Skipping path - The Microsoft OneNote Notebook File '" ~ generatePathFromJSONData(onedriveJSONItem) ~ "' is not supported by this client", ["verbose"]);}
						discardDeltaJSONItem = true;
						
						// Add the Parent ID to onenotePackageIdentifiers
						if (itemHasParentReferenceId) {
							// Add this 'id' to onenotePackageIdentifiers as a future 'catch all' for any objects inside this container
							if (!onenotePackageIdentifiers.canFind(objectParentId)) {
								if (debugLogging) {addLogEntry("Adding 'objectParentId' to onenotePackageIdentifiers: " ~ to!string(objectParentId), ["debug"]);}
								onenotePackageIdentifiers ~= objectParentId;
							}
						}						
					}
				}
			}
			
			// Microsoft OneDrive OneNote 'internal recycle bin' items are a 'folder' , with a 'size' but have a specific name 'OneNote_RecycleBin', for example:
			//	{
			//		....
			//		"fileSystemInfo": {
			//			"createdDateTime": "2025-03-10T17:11:15Z",
			//			"lastModifiedDateTime": "2025-03-10T17:11:15Z"
			//		},
			//		"folder": {
			//			"childCount": 2
			//		},
			//		"id": "XXXXX",
			//		"lastModifiedBy": {
			//			XXXXX
			//		},
			//		"name": "OneNote_RecycleBin",
			//		"parentReference": {
			//			"driveId": "abcde",
			//			"driveType": "business",
			//			"id": "abcde",
			//			"name": "PARENT NAME - ONENOTE PACKAGE NAME",
			//			"path": "/drives/path/to/parent",
			//			"siteId": "XXXXX"
			//		},
			//		"size": 17468
			//	}
			// 
			// The only way we can block this download is looking at the 'name' component
			if (onedriveJSONItem["name"].str == "OneNote_RecycleBin") {
				// Log that this will be skipped as this this is a Microsoft OneNote item and unsupported
				if (verboseLogging) {addLogEntry("Skipping path - The Microsoft OneNote Notebook Recycle Bin '" ~ generatePathFromJSONData(onedriveJSONItem) ~ "' is not supported by this client", ["verbose"]);}
				discardDeltaJSONItem = true;
				
				// Add the Parent ID to onenotePackageIdentifiers
				if (itemHasParentReferenceId) {
					// Add this 'id' to onenotePackageIdentifiers as a future 'catch all' for any objects inside this container
					if (!onenotePackageIdentifiers.canFind(objectParentId)) {
						if (debugLogging) {addLogEntry("Adding 'objectParentId' to onenotePackageIdentifiers: " ~ to!string(objectParentId), ["debug"]);}
						onenotePackageIdentifiers ~= objectParentId;
					}
				}
			}
			
			// If we are not self-generating a /delta response, check this initial /delta JSON bundle item against the basic checks 
			// of applicability against 'skip_file', 'skip_dir' and 'sync_list'
			// We only do this if we did not generate a /delta response, as generateDeltaResponse() performs the checkJSONAgainstClientSideFiltering()
			// against elements as it is building the /delta compatible response
			// If we blindly just 'check again' all JSON responses then there is potentially double JSON processing going on if we used generateDeltaResponse()
			if (!generateSimulatedDeltaResponse) {
				// Did we already exclude?
				if (!discardDeltaJSONItem) {
					// Check applicability against 'skip_file', 'skip_dir' and 'sync_list'
					discardDeltaJSONItem = checkJSONAgainstClientSideFiltering(onedriveJSONItem);
				}
			}
			
			// Add this JSON item for further processing if this is not being discarded
			if (!discardDeltaJSONItem) {
				// If 'personal' account type, we must validate ["parentReference"]["driveId"] value in this raw JSON
				// Issue #3115 - Validate driveId length
				// What account type is this?
				if (appConfig.accountType == "personal") {
					
					string existingDriveIdEntry = onedriveJSONItem["parentReference"]["driveId"].str;
					string newDriveIdEntry;
					
					// Perform the required length test
					if (existingDriveIdEntry.length < 16) {
						// existingDriveIdEntry value is not 16 characters in length
					
						// Is this 'driveId' in this JSON a 15 character representation of our actual 'driveId' which we have already corrected?
						if (appConfig.defaultDriveId.canFind(existingDriveIdEntry)) {
							// The JSON provided value is our 'driveId'
							// Debug logging for correction
							if (debugLogging) {addLogEntry("ONEDRIVE PERSONAL API BUG (Issue #3072): The provided raw JSON ['parentReference']['driveId'] value is not 16 Characters in length - correcting with validated 'appConfig.defaultDriveId' value", ["debug"]);}
							newDriveIdEntry = appConfig.defaultDriveId;
						} else {
							// No match, potentially a Shared Folder ... 
							// Debug logging for correction
							if (debugLogging) {addLogEntry("ONEDRIVE PERSONAL API BUG (Issue #3072): The provided raw JSON ['parentReference']['driveId'] value is not 16 Characters in length - padding with leading zero's", ["debug"]);}
							// Generate the change
							newDriveIdEntry = to!string(existingDriveIdEntry.padLeft('0', 16)); // Explicitly use padLeft for leading zero padding, leave case as-is
						}
						
						// Make the change to the JSON data before submit for further processing
						onedriveJSONItem["parentReference"]["driveId"] = newDriveIdEntry;
					}
				}
			
				// Add onedriveJSONItem to jsonItemsToProcess
				if (debugLogging) {
					addLogEntry("Adding this raw JSON OneDrive Item to jsonItemsToProcess array for further processing", ["debug"]);
					if (itemIsRemoteItem) {
						addLogEntry("- This JSON record represents a online remote folder, thus needs special handling when being processed further", ["debug"]);
					}
				}
				jsonItemsToProcess ~= onedriveJSONItem;
			} else {
				// detail we are discarding the json
				if (debugLogging) {addLogEntry("Discarding this raw JSON OneDrive Item as this has been determined to be unwanted", ["debug"]);}
			}
		}
		
		// How long to initially process this JSON item
		if (debugLogging) {
			Duration jsonProcessingElapsedTime = MonoTime.currTime() - jsonProcessingStartTime;
			addLogEntry("Initial JSON item processing time: " ~ to!string(jsonProcessingElapsedTime), ["debug"]);
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Process 'root' and 'deleted' OneDrive JSON items
	void processRootAndDeletedJSONItems(JSONValue onedriveJSONItem, string driveId, bool handleItemAsRootObject, bool itemIsDeletedOnline, bool itemHasParentReferenceId) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Use the JSON elements rather can computing a DB struct via makeItem()
		string thisItemId = onedriveJSONItem["id"].str;
		string thisItemDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
			
		// Check if the item has been seen before
		Item existingDatabaseItem;
		bool existingDBEntry = itemDB.selectById(thisItemDriveId, thisItemId, existingDatabaseItem);
		
		// Is the item deleted online?
		if(!itemIsDeletedOnline) {
			
			// Is the item a confirmed root object?
			
			// The JSON item should be considered a 'root' item if:
			// 1. Contains a ["root"] element
			// 2. Has no ["parentReference"]["id"] ... #323 & #324 highlighted that this is false as some 'root' shared objects now can have an 'id' element .. OneDrive API change
			// 2. Has no ["parentReference"]["path"]
			// 3. Was detected by an input flag as to be handled as a root item regardless of actual status
			
			if ((handleItemAsRootObject) || (!itemHasParentReferenceId)) {
				if (debugLogging) {addLogEntry("Handing JSON object as OneDrive 'root' object", ["debug"]);}
				if (!existingDBEntry) {
					// we have not seen this item before
					saveItem(onedriveJSONItem);
				}
			}
		} else {
			// Change is to delete an item
			if (debugLogging) {addLogEntry("Handing a OneDrive Online Deleted Item", ["debug"]);}
			if (existingDBEntry) {
				// Is the item to delete locally actually in sync with OneDrive currently?
				// What is the source of this item data?
				string itemSource = "online";
				
				// Compute this deleted items path based on the database entries
				string localPathToDelete = computeItemPath(existingDatabaseItem.driveId, existingDatabaseItem.parentId) ~ "/" ~ existingDatabaseItem.name;
				if (isItemSynced(existingDatabaseItem, localPathToDelete, itemSource)) {
					// Flag to delete
					if (debugLogging) {addLogEntry("Flagging to delete item locally due to online deletion event: " ~ to!string(onedriveJSONItem), ["debug"]);}
					// Use the DB entries returned - add the driveId, itemId and parentId values  to the array
					idsToDelete ~= [existingDatabaseItem.driveId, existingDatabaseItem.id, existingDatabaseItem.parentId];
				} else {
					// If local data protection is configured (bypassDataPreservation = false), safeBackup the local file, passing in if we are performing a --dry-run or not
					// In case the renamed path is needed
					string renamedPath;
					safeBackup(localPathToDelete, dryRun, bypassDataPreservation, renamedPath);
				}
			} else {
				// Flag to ignore
				if (debugLogging) {addLogEntry("Flagging item to skip: " ~ to!string(onedriveJSONItem), ["debug"]);}
				skippedItems.insert(thisItemId);
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Process each of the elements contained in jsonItemsToProcess[]
	void processJSONItemsInBatch(JSONValue[] array, long batchGroup, long batchCount) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		long batchElementCount = array.length;
		MonoTime jsonProcessingStartTime;

		foreach (i, onedriveJSONItem; array.enumerate) {
			// Use the JSON elements rather can computing a DB struct via makeItem()
			long elementCount = i +1;
			jsonProcessingStartTime = MonoTime.currTime();
			
			// To show this is the processing for this particular item, start off with this breaker line
			if (debugLogging) {
				addLogEntry(debugLogBreakType1, ["debug"]);
				addLogEntry("Processing OneDrive JSON item " ~ to!string(elementCount) ~ " of " ~ to!string(batchElementCount) ~ " as part of JSON Item Batch " ~ to!string(batchGroup) ~ " of " ~ to!string(batchCount), ["debug"]);
				addLogEntry("Raw JSON OneDrive Item (Batched Item): " ~ to!string(onedriveJSONItem), ["debug"]);
			}
			
			// Configure required items from the JSON elements
			string thisItemId = onedriveJSONItem["id"].str;
			string thisItemDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
			string thisItemParentId = onedriveJSONItem["parentReference"]["id"].str;
			string thisItemName = onedriveJSONItem["name"].str;
			
			// Create an empty item struct for an existing DB item
			Item existingDatabaseItem;
			
			// Do we NOT want this item?
			bool unwanted = false; // meaning by default we will WANT this item
			// Is this parent is in the database
			bool parentInDatabase = false;
			// Is this the 'root' folder of a Shared Folder
			bool rootSharedFolder = false;
			
			// What is the full path of the new item
			string computedItemPath;
			string newItemPath;
			
			// Configure the remoteItem - so if it is used, it can be utilised later
			Item remoteItem;
			
			// Issue #3336 - Convert driveId to lowercase before any test
			if (appConfig.accountType == "personal") {
				thisItemDriveId = transformToLowerCase(thisItemDriveId);
			}
			
			// Check the database for an existing entry for this JSON item
			bool existingDBEntry = itemDB.selectById(thisItemDriveId, thisItemId, existingDatabaseItem);
			
			// Calculate if the Parent Item is in the database so that it can be re-used
			parentInDatabase = itemDB.idInLocalDatabase(thisItemDriveId, thisItemParentId);
			
			// Calculate the local path of this JSON item, but we can only do this if the parent is in the database
			if (parentInDatabase) {
				// Use the original method of calculation for Personal Accounts
				if (appConfig.accountType == "personal") {
					// Personal Accounts
					// Compute the full local path for an item based on its position within the OneDrive hierarchy
					newItemPath = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ thisItemName;
				} else {
					// Business Accounts
					// Compute the full local path for an item based on its position within the OneDrive hierarchy
					// This also accounts for Shared Folders in our account root, plus Shared Folders in a folder (relocated shared folders)
					computedItemPath = computeItemPath(thisItemDriveId, thisItemParentId);
					
					// Is 'thisItemParentId' in the DB as a 'root' object?
					Item databaseItem;
					
					// Is this a remote drive?
					if (thisItemDriveId != appConfig.defaultDriveId) {
						// query the database for the actual thisItemParentId record
						itemDB.selectById(thisItemDriveId, thisItemParentId, databaseItem);
					}
					
					// Calculate newItemPath to
					// This needs to factor in:
					// - Shared Folders = ItemType.root with a name of 'root'
					// - SharePoint Document Root = ItemType.root with a name of the actual shared folder
					// - Relocatable Shared Folders where a user moves a Shared Folder Link to a sub folder elsewhere within their directory structure online
					if (databaseItem.type == ItemType.root) {
						// 'root' database object
						if (databaseItem.name == "root") {
							// OneDrive Business Shared Folder 'root' shortcut link
							// If the record type is now a root record, we dont want to add the name to itself
							newItemPath = computedItemPath;
						} else {
							// OneDrive Business SharePoint Document 'root' shortcut link
							if (databaseItem.name == thisItemName) {
								// If the record type is now a root record, we dont want to add the name to itself
								newItemPath = computedItemPath;
							} else {
								// add the item name to the computed path
								newItemPath = computedItemPath ~ "/" ~ thisItemName;
							}
						}
						
						// Set this for later use
						rootSharedFolder = true;
					} else {
						// Add the item name to the computed path
						newItemPath = computedItemPath ~ "/" ~ thisItemName;
					}
				}
				
				// debug logging of what was calculated
				if (debugLogging) {addLogEntry("JSON Item calculated full path is: " ~ newItemPath, ["debug"]);}
			} else {
				// Parent not in the database
				// Is the parent a 'folder' from another user? ie - is this a 'shared folder' that has been shared with us?
				
				// Issue #3336 - Convert driveId to lowercase before any test
				if (appConfig.accountType == "personal") {
					thisItemDriveId = transformToLowerCase(thisItemDriveId);
				}
				
				// Lets determine why?
				if (thisItemDriveId == appConfig.defaultDriveId) {
					// Parent path does not exist - flagging as unwanted
					if (debugLogging) {addLogEntry("Flagging as unwanted: thisItemDriveId (" ~ thisItemDriveId ~ "), thisItemParentId (" ~ thisItemParentId ~ ") not in local database", ["debug"]);}
					// Was this a skipped item?
					if (thisItemParentId in skippedItems) {
						// Parent is a skipped item
						if (debugLogging) {addLogEntry("Reason: thisItemParentId listed within skippedItems", ["debug"]);}
					} else {
						// Parent is not in the database, as we are not creating it
						if (debugLogging) {addLogEntry("Reason: Parent ID is not in the DB .. ", ["debug"]);}
					}
					
					// Flag as unwanted
					unwanted = true;	
				} else {
					// Format the OneDrive change into a consumable object for the database
					remoteItem = makeItem(onedriveJSONItem);
					
					// Edge case as the parent (from another users OneDrive account) will never be in the database - potentially a shared object?
					if (debugLogging) {
						addLogEntry("The reported parentId is not in the database. This potentially is a shared folder as 'remoteItem.driveId' != 'appConfig.defaultDriveId'. Relevant Details: remoteItem.driveId (" ~ remoteItem.driveId ~ "), remoteItem.parentId (" ~ remoteItem.parentId ~ ")", ["debug"]);
						addLogEntry("Potential Shared Object JSON: " ~ sanitiseJSONItem(onedriveJSONItem), ["debug"]);
					}

					// What account type is this?					
					if (appConfig.accountType == "personal") {
						// Personal Account Handling
						if (debugLogging) {addLogEntry("Handling a Personal Shared Item JSON object", ["debug"]);}
						
						// Does the JSON have a shared element structure
						if (hasSharedElement(onedriveJSONItem)) {
							// Has the Shared JSON structure
							if (debugLogging) {addLogEntry("Personal Shared Item JSON object has the 'shared' JSON structure", ["debug"]);}
							// Create a 'root' and 'Shared Folder' DB Tie Records for this JSON object in a consistent manner
							createRequiredSharedFolderDatabaseRecords(onedriveJSONItem);
						} else {
							// The Shared JSON structure is missing .....
							if (debugLogging) {addLogEntry("Personal Shared Item JSON object is MISSING the 'shared' JSON structure ... API BUG ?", ["debug"]);}
						}
						
						// Ensure that this item has no parent
						if (debugLogging) {addLogEntry("Setting remoteItem.parentId of Personal Shared Item JSON object to be null", ["debug"]);}
						remoteItem.parentId = null;
						
						// Add this record to the local database
						if (debugLogging) {addLogEntry("Update/Insert local database with Personal Shared Item JSON object with remoteItem.parentId as null: " ~ to!string(remoteItem), ["debug"]);}
						itemDB.upsert(remoteItem);
						
						// Due to OneDrive API inconsistency with Personal Accounts, again with European Data Centres, as we have handled this JSON - flag as unwanted as processing is complete for this JSON item
						unwanted = true;
					} else {
						// Business or SharePoint Account Handling
						if (debugLogging) {addLogEntry("Handling a Business or SharePoint Shared Item JSON object", ["debug"]);}
						
						if (appConfig.accountType == "business") {
							// Create a 'root' and 'Shared Folder' DB Tie Records for this JSON object in a consistent manner
							createRequiredSharedFolderDatabaseRecords(onedriveJSONItem);
							
							// Ensure that this item has no parent
							if (debugLogging) {addLogEntry("Setting remoteItem.parentId to be null", ["debug"]);}
							remoteItem.parentId = null;
							
							// Check the DB for 'remote' objects, searching 'remoteDriveId' and 'remoteId' items for this remoteItem.driveId and remoteItem.id
							Item remoteDBItem;
							itemDB.selectByRemoteId(remoteItem.driveId, remoteItem.id, remoteDBItem);
							
							// Must compare remoteDBItem.name with remoteItem.name
							if ((!remoteDBItem.name.empty) && (remoteDBItem.name != remoteItem.name)) {
								// Update DB Item
								if (debugLogging) {
									addLogEntry("The shared item stored in OneDrive, has a different name to the actual name on the remote drive", ["debug"]);
									addLogEntry("Updating remoteItem.name JSON data with the actual name being used on account drive and local folder", ["debug"]);
									addLogEntry("remoteItem.name was:              " ~ remoteItem.name, ["debug"]);
									addLogEntry("Updating remoteItem.name to:      " ~ remoteDBItem.name, ["debug"]);
								}
								remoteItem.name = remoteDBItem.name;
								if (debugLogging) {addLogEntry("Setting remoteItem.remoteName to: " ~ onedriveJSONItem["name"].str, ["debug"]);}
								
								// Update JSON Item
								remoteItem.remoteName = onedriveJSONItem["name"].str;
								if (debugLogging) {
									addLogEntry("Updating source JSON 'name' to that which is the actual local directory", ["debug"]);
									addLogEntry("onedriveJSONItem['name'] was:         " ~ onedriveJSONItem["name"].str, ["debug"]);
									addLogEntry("Updating onedriveJSONItem['name'] to: " ~ remoteDBItem.name, ["debug"]);
								}
								onedriveJSONItem["name"] = remoteDBItem.name;
								if (debugLogging) {addLogEntry("onedriveJSONItem['name'] now:         " ~ onedriveJSONItem["name"].str, ["debug"]);}
								
								// Update newItemPath value
								newItemPath = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ remoteDBItem.name;
								if (debugLogging) {addLogEntry("New Item updated calculated full path is: " ~ newItemPath, ["debug"]);}
							}
								
							// Add this record to the local database
							if (debugLogging) {addLogEntry("Update/Insert local database with remoteItem details: " ~ to!string(remoteItem), ["debug"]);}
							itemDB.upsert(remoteItem);
						} else {
							// Sharepoint account type
							addLogEntry("Handling a SharePoint Shared Item JSON object - NOT IMPLEMENTED YET ........ RAISE A BUG PLEASE", ["info"]);
						}
					}
				}
			}
			
			// Check the skippedItems array for the parent id of this JSONItem if this is something we need to skip
			if (!unwanted) {
				if (thisItemParentId in skippedItems) {
					// Flag this JSON item as unwanted
					if (debugLogging) {addLogEntry("Flagging as unwanted: find(thisItemParentId).length != 0", ["debug"]);}
					unwanted = true;
					
					// Is this item id in the database?
					if (existingDBEntry) {
						// item exists in database, most likely moved out of scope for current client configuration
						if (debugLogging) {addLogEntry("This item was previously synced / seen by the client", ["debug"]);}
						
						if (("name" in onedriveJSONItem["parentReference"]) != null) {
							
							// How is this item now out of scope?
							// is sync_list configured
							if (syncListConfigured) {
								// sync_list configured and in use
								if (selectiveSync.isPathExcludedViaSyncList(onedriveJSONItem["parentReference"]["name"].str)) {
									// Previously synced item is now out of scope as it has been moved out of what is included in sync_list
									if (debugLogging) {addLogEntry("This previously synced item is now excluded from being synced due to sync_list exclusion", ["debug"]);}
								}
							}
							// flag to delete local file as it now is no longer in sync with OneDrive
							if (verboseLogging) {addLogEntry("Flagging to delete item locally as this is now an unwanted item (parental exclusion) and the item currently exists in the local database: ", ["verbose"]);}
							// Use the configured values - add the driveId, itemId and parentId values to the array
							idsToDelete ~= [thisItemDriveId, thisItemId, thisItemParentId];
						}
					}	
				}
			}
			
			// Check the item type - if it not an item type that we support, we cant process the JSON item
			if (!unwanted) {
				if (isItemFile(onedriveJSONItem)) {
					if (debugLogging) {addLogEntry("The JSON item we are processing is a file", ["debug"]);}
				} else if (isItemFolder(onedriveJSONItem)) {
					if (debugLogging) {addLogEntry("The JSON item we are processing is a folder", ["debug"]);}
				} else if (isItemRemote(onedriveJSONItem)) {
					if (debugLogging) {addLogEntry("The JSON item we are processing is a remote item", ["debug"]);}
				} else {
					// Why was this unwanted?
					if (newItemPath.empty) {
						if (debugLogging) {addLogEntry("OOPS: newItemPath is empty ....... need to calculate it", ["debug"]);}
						// Compute this item path & need the full path for this file
						newItemPath = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ thisItemName;
						if (debugLogging) {addLogEntry("New Item calculated full path is: " ~ newItemPath, ["debug"]);}
					}
					// Microsoft OneNote container objects present as neither folder or file but has file size
					if ((!isItemFile(onedriveJSONItem)) && (!isItemFolder(onedriveJSONItem)) && (hasFileSize(onedriveJSONItem))) {
						// Log that this was skipped as this was a Microsoft OneNote item and unsupported
						if (verboseLogging) {addLogEntry("The Microsoft OneNote Notebook '" ~ newItemPath ~ "' is not supported by this client", ["verbose"]);}
					} else {
						// Log that this item was skipped as unsupported 
						if (verboseLogging) {addLogEntry("The OneDrive item '" ~ newItemPath ~ "' is not supported by this client", ["verbose"]);}
					}
					unwanted = true;
					if (debugLogging) {addLogEntry("Flagging as unwanted: item type is not supported", ["debug"]);}
				}
			}
			
			// Check if this is excluded by config option: skip_dir
			if (!unwanted) {
				// Only check path if config is != ""
				if (!appConfig.getValueString("skip_dir").empty) {
					// Is the item a folder or a remote item? (which itself is a directory, but is missing the 'folder' JSON element we use to determine JSON being a directory or not)
					if ((isItemFolder(onedriveJSONItem)) || (isRemoteFolderItem(onedriveJSONItem))) {
						// work out the 'snippet' path where this folder would be created
						string simplePathToCheck = "";
						string complexPathToCheck = "";
						string matchDisplay = "";
						
						if (hasParentReference(onedriveJSONItem)) {
							// we need to workout the FULL path for this item
							// simple path calculation
							if (("name" in onedriveJSONItem["parentReference"]) != null) {
								// how do we build the simplePathToCheck path up ?
								// did we flag this as the root shared folder object earlier?
								if (rootSharedFolder) {
									// just use item name
									simplePathToCheck = onedriveJSONItem["name"].str;
								} else {
									// add parent name to item name
									simplePathToCheck = onedriveJSONItem["parentReference"]["name"].str ~ "/" ~ onedriveJSONItem["name"].str;
								}
							} else {
								// just use item name
								simplePathToCheck = onedriveJSONItem["name"].str;
							}
							if (debugLogging) {addLogEntry("skip_dir path to check (simple):  " ~ simplePathToCheck, ["debug"]);}
							
							// complex path calculation
							if (parentInDatabase) {
								// build up complexPathToCheck
								complexPathToCheck = buildNormalizedPath(newItemPath);
							} else {
								if (debugLogging) {addLogEntry("Parent details not in database - unable to compute complex path to check", ["debug"]);}
							}
							if (!complexPathToCheck.empty) {
								if (debugLogging) {addLogEntry("skip_dir path to check (complex): " ~ complexPathToCheck, ["debug"]);}
							}
						} else {
							simplePathToCheck = onedriveJSONItem["name"].str;
						}
						
						// If 'simplePathToCheck' or 'complexPathToCheck' is of the following format:  root:/folder
						// then isDirNameExcluded matching will not work
						if (simplePathToCheck.canFind(":")) {
							if (debugLogging) {addLogEntry("Updating simplePathToCheck to remove 'root:'", ["debug"]);}
							simplePathToCheck = processPathToRemoveRootReference(simplePathToCheck);
						}
						if (complexPathToCheck.canFind(":")) {
							if (debugLogging) {addLogEntry("Updating complexPathToCheck to remove 'root:'", ["debug"]);}
							complexPathToCheck = processPathToRemoveRootReference(complexPathToCheck);
						}
						
						// OK .. what checks are we doing?
						if ((!simplePathToCheck.empty) && (complexPathToCheck.empty)) {
							// just a simple check
							if (debugLogging) {addLogEntry("Performing a simple check only", ["debug"]);}
							unwanted = selectiveSync.isDirNameExcluded(simplePathToCheck);
						} else {
							// simple and complex
							if (debugLogging) {addLogEntry("Performing a simple then complex path match if required", ["debug"]);}
							
							// simple first
							if (debugLogging) {addLogEntry("Performing a simple check first", ["debug"]);}
							unwanted = selectiveSync.isDirNameExcluded(simplePathToCheck);
							matchDisplay = simplePathToCheck;
							if (!unwanted) {
								// simple didnt match, perform a complex check
								if (debugLogging) {addLogEntry("Simple match was false, attempting complex match", ["debug"]);}
								unwanted = selectiveSync.isDirNameExcluded(complexPathToCheck);
								matchDisplay = complexPathToCheck;
							}
						}
						// result
						if (debugLogging) {addLogEntry("skip_dir exclude result (directory based): " ~ to!string(unwanted), ["debug"]);}
						if (unwanted) {
							// This path should be skipped
							if (verboseLogging) {addLogEntry("Skipping path - excluded by skip_dir config: " ~ matchDisplay, ["verbose"]);}
						}
					}
					// Is the item a file?
					// We need to check to see if this files path is excluded as well
					if (isItemFile(onedriveJSONItem)) {
					
						string pathToCheck;
						// does the newItemPath start with '/'?
						if (!startsWith(newItemPath, "/")){
							// path does not start with '/', but we need to check skip_dir entries with and without '/'
							// so always make sure we are checking a path with '/'
							pathToCheck = '/' ~ dirName(newItemPath);
						} else {
							pathToCheck = dirName(newItemPath);
						}
						
						// perform the check
						unwanted = selectiveSync.isDirNameExcluded(pathToCheck);
						// result
						if (debugLogging) {addLogEntry("skip_dir exclude result (file based): " ~ to!string(unwanted), ["debug"]);}
						if (unwanted) {
							// this files path should be skipped
							if (verboseLogging) {addLogEntry("Skipping file - file path is excluded by skip_dir config: " ~ newItemPath, ["verbose"]);}
						}
					}
				}
			}
			
			// Check if this is excluded by config option: skip_file
			if (!unwanted) {
				// Is the JSON item a file?
				if (isItemFile(onedriveJSONItem)) {
					// skip_file can contain 4 types of entries:
					// - wildcard - *.txt
					// - text + wildcard - name*.txt
					// - full path + combination of any above two - /path/name*.txt
					// - full path to file - /path/to/file.txt
					
					// is the parent id in the database?
					if (parentInDatabase) {
						// Compute this item path & need the full path for this file
						if (newItemPath.empty) {
							if (debugLogging) {addLogEntry("OOPS: newItemPath is empty ....... need to calculate it", ["debug"]);}
							newItemPath = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ thisItemName;
							if (debugLogging) {addLogEntry("New Item calculated full path is: " ~ newItemPath, ["debug"]);}
						}
						
						// The path that needs to be checked needs to include the '/'
						// This due to if the user has specified in skip_file an exclusive path: '/path/file' - that is what must be matched
						// However, as 'path' used throughout, use a temp variable with this modification so that we use the temp variable for exclusion checks
						string exclusionTestPath = "";
						if (!startsWith(newItemPath, "/")){
							// Add '/' to the path
							exclusionTestPath = '/' ~ newItemPath;
						}
						
						if (debugLogging) {addLogEntry("skip_file item to check: " ~ exclusionTestPath, ["debug"]);}
						unwanted = selectiveSync.isFileNameExcluded(exclusionTestPath);
						if (debugLogging) {addLogEntry("Result: " ~ to!string(unwanted), ["debug"]);}
						if (unwanted) {
							if (verboseLogging) {addLogEntry("Skipping file - excluded by skip_file config: " ~ thisItemName, ["verbose"]);}
						}
					} else {
						// parent id is not in the database
						unwanted = true;
						if (verboseLogging) {addLogEntry("Skipping file - parent path not present in local database", ["verbose"]);}
					}
				}
			}
			
			// Check if this is included or excluded by use of sync_list
			if (!unwanted) {
				// No need to try and process something against a sync_list if it has been configured
				if (syncListConfigured) {
					// Compute the item path if empty - as to check sync_list we need an actual path to check
					if (newItemPath.empty) {
						// Calculate this items path
						if (debugLogging) {addLogEntry("OOPS: newItemPath is empty ....... need to calculate it", ["debug"]);}
						newItemPath = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ thisItemName;
						if (debugLogging) {addLogEntry("New Item calculated full path is: " ~ newItemPath, ["debug"]);}
					}
					
					// What path are we checking?
					if (debugLogging) {addLogEntry("Path to check against 'sync_list' entries: " ~ newItemPath, ["debug"]);}
					
					// Unfortunately there is no avoiding this call to check if the path is excluded|included via sync_list
					if (selectiveSync.isPathExcludedViaSyncList(newItemPath)) {
						// selective sync advised to skip, however is this a file and are we configured to upload / download files in the root?
						if ((isItemFile(onedriveJSONItem)) && (appConfig.getValueBool("sync_root_files")) && (rootName(newItemPath) == "") ) {
							// This is a file
							// We are configured to sync all files in the root
							// This is a file in the logical root
							unwanted = false;
						} else {
							// path is unwanted - excluded by 'sync_list'
							unwanted = true;
							if (verboseLogging) {addLogEntry("Skipping path - excluded by sync_list config: " ~ newItemPath, ["verbose"]);}
							// flagging to skip this item now, but does this exist in the DB thus needs to be removed / deleted?
							if (existingDBEntry) {
								// flag to delete
								if (verboseLogging) {addLogEntry("Flagging to delete item locally as this is now an unwanted item (sync_list exclusion) and the item currently exists in the local database: ", ["verbose"]);}
								// Use the configured values - add the driveId, itemId and parentId values to the array
								idsToDelete ~= [thisItemDriveId, thisItemId, thisItemParentId];
							}
						}
					}
				}
			}
			
			// Check if the user has configured to skip downloading .files or .folders: skip_dotfiles
			if (!unwanted) {
				if (appConfig.getValueBool("skip_dotfiles")) {
					if (isDotFile(newItemPath)) {
						if (verboseLogging) {addLogEntry("Skipping item - .file or .folder: " ~ newItemPath, ["verbose"]);}
						unwanted = true;
					}
				}
			}
			
			// Check if this should be skipped due to a --check-for-nosync directive (.nosync)?
			if (!unwanted) {
				if (appConfig.getValueBool("check_nosync")) {
					// need the parent path for this object
					string parentPath = dirName(newItemPath);
					// Check for the presence of a .nosync in the parent path
					if (exists(parentPath ~ "/.nosync")) {
						if (verboseLogging) {addLogEntry("Skipping downloading item - .nosync found in parent folder & --check-for-nosync is enabled: " ~ newItemPath, ["verbose"]);}
						unwanted = true;
					}
				}
			}
			
			// Check if this is excluded by a user set maximum filesize to download
			if (!unwanted) {
				if (isItemFile(onedriveJSONItem)) {
					if (fileSizeLimit != 0) {
						if (onedriveJSONItem["size"].integer >= fileSizeLimit) {
							if (verboseLogging) {addLogEntry("Skipping file - excluded by skip_size config: " ~ thisItemName ~ " (" ~ to!string(onedriveJSONItem["size"].integer/2^^20) ~ " MB)", ["verbose"]);}
							unwanted = true;
						}
					}
				}
			}
			
			// At this point all the applicable checks on this JSON object from OneDrive are complete:
			// - skip_file
			// - skip_dir
			// - sync_list
			// - skip_dotfiles
			// - check_nosync
			// - skip_size
			// - We know if this item exists in the DB or not in the DB
			
			// We know if this JSON item is unwanted or not
			if (unwanted) {
				// This JSON item is NOT wanted - it is excluded
				if (debugLogging) {addLogEntry("Skipping OneDrive JSON item as this is determined to be unwanted either through Client Side Filtering Rules or prior processing to this point", ["debug"]);}
				
				// Add to the skippedItems array, but only if it is a directory ... pointless adding 'files' here, as it is the 'id' we check as the parent path which can only be a directory
				if (!isItemFile(onedriveJSONItem)) {
					skippedItems.insert(thisItemId);
				}
			} else {
				// This JSON item is wanted - we need to process this JSON item further
				if (debugLogging) {
					addLogEntry("OneDrive JSON item passed all applicable Client Side Filtering Rules and has been determined this is a wanted item", ["debug"]);
					addLogEntry("Creating newDatabaseItem object using the provided JSON data", ["debug"]);
				}
				
				// Take the JSON item and create a consumable object for eventual database insertion
				Item newDatabaseItem = makeItem(onedriveJSONItem);
				
				if (existingDBEntry) {
					// The details of this JSON item are already in the DB
					// Is the item in the DB the same as the JSON data provided - or is the JSON data advising this is an updated file?
					if (debugLogging) {addLogEntry("OneDrive JSON item is an update to an existing local item", ["debug"]);}
					
					// Compute the existing item path
					// NOTE:
					//		string existingItemPath = computeItemPath(existingDatabaseItem.driveId, existingDatabaseItem.id);
					//
					// This will calculate the path as follows:
					//
					//		existingItemPath:     Document.txt
					//
					// Whereas above we use the following
					//
					//		newItemPath = computeItemPath(newDatabaseItem.driveId, newDatabaseItem.parentId) ~ "/" ~ newDatabaseItem.name;
					//
					// Which generates the following path:
					//
					//  	changedItemPath:      ./Document.txt
					// 
					// Need to be consistent here with how 'newItemPath' was calculated
					string queryDriveID;
					string queryParentID;
					
					// Must query with a valid driveid entry
					if (existingDatabaseItem.driveId.empty) {
						queryDriveID = thisItemDriveId;
					} else {
						queryDriveID = existingDatabaseItem.driveId;
					}
					
					// Must query with a valid parentid entry
					if (existingDatabaseItem.parentId.empty) {
						queryParentID = thisItemParentId;
					} else {
						queryParentID = existingDatabaseItem.parentId;
					}
					
					// Calculate the existing path
					string existingItemPath = computeItemPath(queryDriveID, queryParentID) ~ "/" ~ existingDatabaseItem.name;
					if (debugLogging) {addLogEntry("existingItemPath calculated full path is: " ~ existingItemPath, ["debug"]);}
					
					// Attempt to apply this changed item
					applyPotentiallyChangedItem(existingDatabaseItem, existingItemPath, newDatabaseItem, newItemPath, onedriveJSONItem);
				} else {
					// Action this JSON item as a new item as we have no DB record of it
					// The actual item may actually exist locally already, meaning that just the database is out-of-date or missing the data due to --resync
					// But we also cannot compute the newItemPath as the parental objects may not exist as well
					if (debugLogging) {addLogEntry("OneDrive JSON item is potentially a new local item", ["debug"]);}
					
					// Attempt to apply this potentially new item
					applyPotentiallyNewLocalItem(newDatabaseItem, onedriveJSONItem, newItemPath);
				}
			}
			
			// How long to process this JSON item in batch
			if (debugLogging) {
				Duration jsonProcessingElapsedTime = MonoTime.currTime() - jsonProcessingStartTime;
				addLogEntry("Batched JSON item processing time: " ~ to!string(jsonProcessingElapsedTime), ["debug"]);
			}
			
			// Tracking as to if this item was processed
			processedCount++;
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Perform the download of any required objects in parallel
	void processDownloadActivities() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
			
		// Are there any items to delete locally? Cleanup space locally first
		if (!idsToDelete.empty) {
			// There are elements that potentially need to be deleted locally
			if (verboseLogging) {addLogEntry("Items to potentially delete locally: " ~ to!string(idsToDelete.length), ["verbose"]);}
			
			if (appConfig.getValueBool("download_only")) {
				// Download only has been configured
				if (cleanupLocalFiles) {
					// Process online deleted items
					if (verboseLogging) {addLogEntry("Processing local deletion activity as --download-only & --cleanup-local-files configured", ["verbose"]);}
					processDeleteItems();
				} else {
					// Not cleaning up local files
					if (verboseLogging) {addLogEntry("Skipping local deletion activity as --download-only has been used", ["verbose"]);}
					// List files and directories we are not deleting locally
					listDeletedItems();
				}
			} else {
				// Not using --download-only process normally
				processDeleteItems();
			}
			// Cleanup array memory
			idsToDelete = [];
		}
		
		// Are there any items to download post fetching and processing the /delta data?
		if (!fileJSONItemsToDownload.empty) {
			// There are elements to download
			addLogEntry("Number of items to download from Microsoft OneDrive: " ~ to!string(fileJSONItemsToDownload.length));
			downloadOneDriveItems();
			// Cleanup array memory
			fileJSONItemsToDownload = [];
		}
		
		// Are there any skipped items still?
		if (!skippedItems.empty) {
			// Cleanup array memory
			skippedItems.clear();
		}
		
		// If deltaLinkCache.latestDeltaLink is not empty, update the deltaLink in the database for this driveId so that we can reuse this now that jsonItemsToProcess has been fully processed
		if (!deltaLinkCache.latestDeltaLink.empty) {
			if (debugLogging) {addLogEntry("Updating completed deltaLink for driveID " ~ deltaLinkCache.driveId ~ " in DB to: " ~ deltaLinkCache.latestDeltaLink, ["debug"]);}
			itemDB.setDeltaLink(deltaLinkCache.driveId, deltaLinkCache.itemId, deltaLinkCache.latestDeltaLink);
			
			// Now that the DB is updated, when we perform the last examination of the most recent online data, cache this so this can be obtained this from memory
			cacheLatestDeltaLink(deltaLinkInfo, deltaLinkCache.driveId, deltaLinkCache.latestDeltaLink);		
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Function to add or update a key pair in the deltaLinkInfo array
	void cacheLatestDeltaLink(ref DeltaLinkInfo deltaLinkInfo, string driveId, string latestDeltaLink) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		if (driveId !in deltaLinkInfo) {
			if (debugLogging) {addLogEntry("Added new latestDeltaLink entry: " ~ driveId ~ " -> " ~ latestDeltaLink, ["debug"]);}
		} else {
			if (debugLogging) {addLogEntry("Updated latestDeltaLink entry for " ~ driveId ~ " from " ~ deltaLinkInfo[driveId] ~ " to " ~ latestDeltaLink, ["debug"]);}
		}
		deltaLinkInfo[driveId] = latestDeltaLink;
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Function to get the latestDeltaLink based on driveId
	string getDeltaLinkFromCache(ref DeltaLinkInfo deltaLinkInfo, string driveId) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		string cachedDeltaLink;
		if (driveId in deltaLinkInfo) {
			cachedDeltaLink = deltaLinkInfo[driveId];
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// return value
		return cachedDeltaLink;
	}
	
	// If the JSON item is not in the database, it is potentially a new item that we need to action
	void applyPotentiallyNewLocalItem(Item newDatabaseItem, JSONValue onedriveJSONItem, string newItemPath) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Due to this function, we need to keep the 'return' code as-is, so that this function operates as efficiently as possible.
		// Whilst this means some extra code / duplication in this function, it cannot be helped
			
		// The JSON and Database items being passed in here have passed the following checks:
		// - skip_file
		// - skip_dir
		// - sync_list
		// - skip_dotfiles
		// - check_nosync
		// - skip_size
		// - Is not currently cached in the local database
		// As such, we should not be doing any other checks here to determine if the JSON item is wanted .. it is
		
		if (exists(newItemPath)) {
			if (debugLogging) {addLogEntry("Path on local disk already exists", ["debug"]);}
			// Issue #2209 fix - test if path is a bad symbolic link
			if (isSymlink(newItemPath)) {
				if (debugLogging) {addLogEntry("Path on local disk is a symbolic link ........", ["debug"]);}
				if (!exists(readLink(newItemPath))) {
					// reading the symbolic link failed	
					if (debugLogging) {addLogEntry("Reading the symbolic link target failed ........ ", ["debug"]);}
					addLogEntry("Skipping item - invalid symbolic link: " ~ newItemPath, ["info", "notify"]);
					
					// Display function processing time if configured to do so
					if (appConfig.getValueBool("display_processing_time") && debugLogging) {
						// Combine module name & running Function
						displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
					}
					
					// return - invalid symbolic link
					return;
				}
			}
			
			// Path exists locally, is not a bad symbolic link
			// Test if this item is actually in-sync
			// What is the source of this item data?
			string itemSource = "remote";
			if (isItemSynced(newDatabaseItem, newItemPath, itemSource)) {
				// Issue #3115 - Personal Account Shared Folder
				// What account type is this?
				if (appConfig.accountType == "personal") {
					// Is this a 'remote' DB record
					if (newDatabaseItem.type == ItemType.remote) {
						// Issue #3136, #3139 #3143
						// Fetch the actual online record for this item
						// This returns the 'actual' OneDrive Personal driveId value and is 15 character checked
						string actualOnlineDriveId = testProvidedDriveIdForLengthIssue(fetchRealOnlineDriveIdentifier(newDatabaseItem.remoteDriveId));
						newDatabaseItem.remoteDriveId = actualOnlineDriveId;
					}
				}
			
				// Item details from OneDrive and local item details in database are in-sync
				if (debugLogging) {
					addLogEntry("The item to sync is already present on the local filesystem and is in-sync with what is reported online", ["debug"]);
					addLogEntry("Update/Insert local database with item details: " ~ to!string(newDatabaseItem), ["debug"]);
				}
				
				// Add item to database
				itemDB.upsert(newDatabaseItem);
				
				// With the 'newDatabaseItem' saved to the database, regardless of --dry-run situation - was that new database item a 'remote' item?
				// If this is this a 'Shared Folder' item - ensure we have created / updated any relevant Database Tie Records
				// This should be applicable for all account types
				if (newDatabaseItem.type == ItemType.remote) {
					// yes this is a remote item type
					if (debugLogging) {addLogEntry("The 'newDatabaseItem' (applyPotentiallyNewLocalItem) is a remote item type - we need to create all of the associated database tie records for this database entry" , ["debug"]);}
					
					string relocatedFolderDriveId;
					string relocatedFolderParentId;
					
					// Is this a relocated Shared Folder? OneDrive Business supports the relocation of Shared Folder links to other folders
					if (appConfig.accountType != "personal") {
						// Is this parentId equal to our defaultRootId .. if not it is highly likely that this Shared Folder is in a sub folder in our online folder structure
						if (newDatabaseItem.parentId != appConfig.defaultRootId) {
							// The parentId is not our defaultRootId .. most likely a relocated shared folder
							if (debugLogging) {
								addLogEntry("The folder path for this Shared Folder is not our account root, thus is a relocated Shared Folder item. We must pass in the correct parent details for this Shared Folder 'root' object" , ["debug"]);
								// What are we setting
								addLogEntry("Setting relocatedFolderDriveId to:  " ~ newDatabaseItem.driveId);
								addLogEntry("Setting relocatedFolderParentId to: " ~ newDatabaseItem.parentId);
							}
							
							// Configure the relocated folders data
							relocatedFolderDriveId = newDatabaseItem.driveId;
							relocatedFolderParentId = newDatabaseItem.parentId;
						}
					}
					
					// Create a 'root' and 'Shared Folder' DB Tie Records for this JSON object in a consistent manner
					// We pass in the JSON element so we can create the right records + if this is a relocated shared folder, give the local parental record identifier
					createRequiredSharedFolderDatabaseRecords(onedriveJSONItem, relocatedFolderDriveId, relocatedFolderParentId);
				}
				
				// Did the user configure to save xattr data about this file?
				if (appConfig.getValueBool("write_xattr_data")) {
					writeXattrData(newItemPath, onedriveJSONItem);
				}
				
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
				
				// all done processing this potential new local item
				return;
			} else {
				// Item details from OneDrive and local item details in database are NOT in-sync
				if (debugLogging) {addLogEntry("The item to sync exists locally but is potentially not in the local database - otherwise this would be handled as changed item", ["debug"]);}
				
				// Which object is newer? The local file or the remote file?
				SysTime localModifiedTime = timeLastModified(newItemPath).toUTC();
				SysTime itemModifiedTime = newDatabaseItem.mtime;
				// Reduce time resolution to seconds before comparing
				localModifiedTime.fracSecs = Duration.zero;
				itemModifiedTime.fracSecs = Duration.zero;
				
				// Is the local modified time greater than that from OneDrive?
				if (localModifiedTime > itemModifiedTime) {
					// Local file is newer than item on OneDrive based on file modified time
					// Is this item id in the database?
					if (itemDB.idInLocalDatabase(newDatabaseItem.driveId, newDatabaseItem.id)) {
						// item id is in the database
						// no local rename
						// no download needed
						
						// Fetch the latest DB record - as this could have been updated by the isItemSynced if the date online was being corrected, then the DB updated as a result
						Item latestDatabaseItem;
						itemDB.selectById(newDatabaseItem.driveId, newDatabaseItem.id, latestDatabaseItem);
						if (debugLogging) {addLogEntry("latestDatabaseItem: " ~ to!string(latestDatabaseItem), ["debug"]);}
						
						SysTime latestItemModifiedTime = latestDatabaseItem.mtime;
						// Reduce time resolution to seconds before comparing
						latestItemModifiedTime.fracSecs = Duration.zero;
						
						if (localModifiedTime == latestItemModifiedTime) {
							// Log action
							if (verboseLogging) {addLogEntry("Local file modified time matches existing database record - keeping local file", ["verbose"]);}
							if (debugLogging) {addLogEntry("Skipping OneDrive change as this is determined to be unwanted due to local file modified time matching database data", ["debug"]);}
						} else {
							// Log action
							if (verboseLogging) {addLogEntry("Local file modified time is newer based on UTC time conversion - keeping local file as this exists in the local database", ["verbose"]);}
							if (debugLogging) {addLogEntry("Skipping OneDrive change as this is determined to be unwanted due to local file modified time being newer than OneDrive file and present in the sqlite database", ["debug"]);}
						}
						
						// Display function processing time if configured to do so
						if (appConfig.getValueBool("display_processing_time") && debugLogging) {
							// Combine module name & running Function
							displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
						}
						
						// Return as no further action needed
						return;
					} else {
						// item id is not in the database .. maybe a --resync ?
						// file exists locally but is not in the sqlite database - maybe a failed download?
						if (verboseLogging) {addLogEntry("Local item does not exist in local database - replacing with file from OneDrive - failed download?", ["verbose"]);}
						
						// In a --resync scenario or if items.sqlite3 was deleted before startup we have zero way of knowing IF the local file is meant to be the right file
						// To this pint we have passed the following checks:
						// 1. Any client side filtering checks - this determined this is a file that is wanted
						// 2. A file with the exact name exists locally
						// 3. The local modified time > remote modified time
						// 4. The id of the item from OneDrive is not in the database
						
						// If local data protection is configured (bypassDataPreservation = false), safeBackup the local file, passing in if we are performing a --dry-run or not
						// In case the renamed path is needed
						string renamedPath;
						safeBackup(newItemPath, dryRun, bypassDataPreservation, renamedPath);
					}
				} else {
					// Is the remote newer?
					if (localModifiedTime < itemModifiedTime) {
						// Remote file is newer than the existing local item
						if (verboseLogging) {addLogEntry("Remote item modified time is newer based on UTC time conversion", ["verbose"]);} // correct message, remote item is newer
						if (debugLogging) {
							addLogEntry("localModifiedTime (local file):   " ~ to!string(localModifiedTime), ["debug"]);
							addLogEntry("itemModifiedTime (OneDrive item): " ~ to!string(itemModifiedTime), ["debug"]);
						}
						
						// Is this the exact same file?
						// Test the file hash
						if (!testFileHash(newItemPath, newDatabaseItem)) {
							// File on disk is different by hash / content
							// If local data protection is configured (bypassDataPreservation = false), safeBackup the local file, passing in if we are performing a --dry-run or not
							// In case the renamed path is needed
							string renamedPath;
							safeBackup(newItemPath, dryRun, bypassDataPreservation, renamedPath);
						} else {
							// File on disk is the same by hash / content, but is a different timestamp
							// The file contents have not changed, but the modified timestamp has
							if (verboseLogging) {addLogEntry("The last modified timestamp online has changed however the local file content has not changed", ["verbose"]);}
							// Update the local timestamp, logging and error handling done within function
							setLocalPathTimestamp(dryRun, newItemPath, newDatabaseItem.mtime);
						}
					}
					
					// Are the timestamps equal?
					if (localModifiedTime == itemModifiedTime) {
						// yes they are equal
						if (debugLogging) {
							addLogEntry("File timestamps are equal, no further action required", ["debug"]); // correct message as timestamps are equal
							addLogEntry("Update/Insert local database with item details: " ~ to!string(newDatabaseItem), ["debug"]);
						}
						
						// Add item to database
						itemDB.upsert(newDatabaseItem);
						
						// Did the user configure to save xattr data about this file?
						if (appConfig.getValueBool("write_xattr_data")) {
							writeXattrData(newItemPath, onedriveJSONItem);
						}
						
						// Display function processing time if configured to do so
						if (appConfig.getValueBool("display_processing_time") && debugLogging) {
							// Combine module name & running Function
							displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
						}
						
						// everything all OK, DB updated
						return;
					}
				}
			}
		} 
			
		// Path does not exist locally (should not exist locally if renamed file) - this will be a new file download or new folder creation
		// How to handle this Potentially New Local Item JSON ?
		final switch (newDatabaseItem.type) {
			case ItemType.file:
				// Add to the file to the download array for processing later
				fileJSONItemsToDownload ~= onedriveJSONItem;
				goto functionCompletion;
				
			case ItemType.dir:
				// Create the directory immediately as we depend on its entry existing
				handleLocalDirectoryCreation(newDatabaseItem, newItemPath, onedriveJSONItem);
				goto functionCompletion;
				
			case ItemType.remote:
				// Add to the directory and relevant details for processing later
				if (newDatabaseItem.remoteType == ItemType.dir) {
					handleLocalDirectoryCreation(newDatabaseItem, newItemPath, onedriveJSONItem);
				} else {
					// Add to the file to the download array for processing later
					fileJSONItemsToDownload ~= onedriveJSONItem;
				}
				goto functionCompletion;
				
			case ItemType.root:
			case ItemType.unknown:
			case ItemType.none:
				// Unknown type - we dont action or sync these items
				goto functionCompletion;
		}
		
		// To correctly handle a switch|case statement we use goto post the switch|case statement as if 'break' is used, we never get to this point
		functionCompletion:
			// Display function processing time if configured to do so
			if (appConfig.getValueBool("display_processing_time") && debugLogging) {
				// Combine module name & running Function
				displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
			}
	}
	
	// Handle the creation of a new local directory
	void handleLocalDirectoryCreation(Item newDatabaseItem, string newItemPath, JSONValue onedriveJSONItem) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// To create a path, 'newItemPath' must not be empty
		if (!newItemPath.empty) {
			// Update the logging output to be consistent
			if (verboseLogging) {addLogEntry("Creating local directory: " ~ "./" ~ buildNormalizedPath(newItemPath), ["verbose"]);}
			if (!dryRun) {
				try {
					// Create the new directory
					if (debugLogging) {addLogEntry("Requested local path does not exist, creating directory structure: " ~ newItemPath, ["debug"]);}
					mkdirRecurse(newItemPath);
					
					// Has the user disabled the setting of filesystem permissions?
					if (!appConfig.getValueBool("disable_permission_set")) {
						// Configure the applicable permissions for the folder
						if (debugLogging) {addLogEntry("Setting directory permissions for: " ~ newItemPath, ["debug"]);}
						newItemPath.setAttributes(appConfig.returnRequiredDirectoryPermissions());
					} else {
						// Use inherited permissions
						if (debugLogging) {addLogEntry("Using inherited filesystem permissions for: " ~ newItemPath, ["debug"]);}
					}
					
					// Update the time of the folder to match the last modified time as is provided by OneDrive
					// If there are any files then downloaded into this folder, the last modified time will get 
					// updated by the local Operating System with the latest timestamp - as this is normal operation
					// as the directory has been modified
					// Set the timestamp, logging and error handling done within function
					setLocalPathTimestamp(dryRun, newItemPath, newDatabaseItem.mtime);
					
					// Save the newDatabaseItem to the database
					saveDatabaseItem(newDatabaseItem);
				} catch (FileException e) {
					// display the error message
					displayFileSystemErrorMessage(e.msg, thisFunctionName);
				}
			} else {
				// we dont create the directory, but we need to track that we 'faked it'
				idsFaked ~= [newDatabaseItem.driveId, newDatabaseItem.id];
				// Save the newDatabaseItem to the database
				saveDatabaseItem(newDatabaseItem);
			}
			
			// With the 'newDatabaseItem' saved to the database, regardless of --dry-run situation - was that new database item a 'remote' item?
			// Is this folder that has been created locally a 'Shared Folder' online?
			// This should be applicable for all account types
			if (newDatabaseItem.type == ItemType.remote) {
				// yes this is a remote item type
				if (debugLogging) {addLogEntry("The 'newDatabaseItem' (handleLocalDirectoryCreation) is a remote item type - we need to create all of the associated database tie records for this database entry" , ["debug"]);}
				
				string relocatedFolderDriveId;
				string relocatedFolderParentId;
				
				// Is this a relocated Shared Folder? OneDrive Business supports the relocation of Shared Folder links to other folders
				if (appConfig.accountType != "personal") {
					// Is this parentId equal to our defaultRootId .. if not it is highly likely that this Shared Folder is in a sub folder in our online folder structure
					if (newDatabaseItem.parentId != appConfig.defaultRootId) {
						// The parentId is not our defaultRootId .. most likely a relocated shared folder
						if (debugLogging) {
							addLogEntry("The folder path for this Shared Folder is not our account root, thus is a relocated Shared Folder item. We must pass in the correct parent details for this Shared Folder 'root' object" , ["debug"]);
							// What are we setting
							addLogEntry("Setting relocatedFolderDriveId to:  " ~ newDatabaseItem.driveId);
							addLogEntry("Setting relocatedFolderParentId to: " ~ newDatabaseItem.parentId);
						}
						
						// Configure the relocated folders data
						relocatedFolderDriveId = newDatabaseItem.driveId;
						relocatedFolderParentId = newDatabaseItem.parentId;
					}
				}
				
				// Create a 'root' and 'Shared Folder' DB Tie Records for this JSON object in a consistent manner
				// We pass in the JSON element so we can create the right records + if this is a relocated shared folder, give the local parental record identifier
				createRequiredSharedFolderDatabaseRecords(onedriveJSONItem, relocatedFolderDriveId, relocatedFolderParentId);
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Create 'root' DB Tie Record and 'Shared Folder' DB Record in a consistent manner
	void createRequiredSharedFolderDatabaseRecords(JSONValue onedriveJSONItem, string relocatedFolderDriveId = null, string relocatedFolderParentId = null) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Due to this function, we need to keep the return code, so that this function operates as efficiently as possible.
		// Whilst this means some extra code / duplication in this function, it cannot be helped
	
		// Detail what we are doing
		if (debugLogging) {addLogEntry("We have been requested to create 'root' and 'Shared Folder' DB Tie Records in a consistent manner" , ["debug"]);}
		
		JSONValue onlineParentData;
		string parentDriveId;
		string parentObjectId;
		OneDriveApi onlineParentOneDriveApiInstance;
		onlineParentOneDriveApiInstance = new OneDriveApi(appConfig);
		onlineParentOneDriveApiInstance.initialise();
		
		// Using the onlineParentData JSON data make a DB record for this parent item so that it exists in the database
		Item sharedFolderDatabaseTie;
		
		// A Shared Folder should have ["remoteItem"]["parentReference"] elements
		bool remoteItemElementsExist = false;
		
		// Test that the required elements exist for Shared Folder DB entry creations to occur
		if (isItemRemote(onedriveJSONItem)) {
			// Required ["remoteItem"] element exists in the JSON data
			if ((hasRemoteParentDriveId(onedriveJSONItem)) && (hasRemoteItemId(onedriveJSONItem))) {
				// Required elements exist
				remoteItemElementsExist = true;
				// What account type is this? This needs to be configured correctly so this can be queried correctly
				// - The setting of this is the 'same' for account types, but previously this was shown to need different data. Future code optimisation potentially here.
				if (appConfig.accountType == "personal") {
					// OneDrive Personal JSON has this structure that we need to use
					parentDriveId = onedriveJSONItem["remoteItem"]["parentReference"]["driveId"].str;
					parentObjectId = onedriveJSONItem["remoteItem"]["id"].str;
				} else {
					// OneDrive Business|Sharepoint JSON has this structure that we need to use
					parentDriveId = onedriveJSONItem["remoteItem"]["parentReference"]["driveId"].str;
					parentObjectId = onedriveJSONItem["remoteItem"]["id"].str;
				}
			}
		}
		
		// If the required elements do not exist, the Shared Folder DB elements cannot be created
		if (!remoteItemElementsExist) {
			// We cannot create the required entries in the database
			if (debugLogging) {addLogEntry("Unable to create 'root' and 'Shared Folder' DB Tie Records in a consistent manner - required elements missing from provided JSON record" , ["debug"]);}
			return;
		}
		
		// Issue #3115 - Validate 'parentDriveId' length
		// What account type is this?
		if (appConfig.accountType == "personal") {
			// Issue #3336 - Convert driveId to lowercase before any test
			parentDriveId = transformToLowerCase(parentDriveId);
			
			// Test if the 'parentDriveId' is not equal to appConfig.defaultDriveId
			if (parentDriveId != appConfig.defaultDriveId) {
				// Test 'parentDriveId' for length and validation - 15 character API bug
				parentDriveId = testProvidedDriveIdForLengthIssue(parentDriveId);
			}
		}
		
		// Try and fetch this shared folder parent's details
		try {
			if (debugLogging) {addLogEntry(format("Fetching Shared Folder online data for parentDriveId '%s' and parentObjectId '%s'", parentDriveId, parentObjectId), ["debug"]);}
			onlineParentData = onlineParentOneDriveApiInstance.getPathDetailsById(parentDriveId, parentObjectId);
		} catch (OneDriveException exception) {
			// If we get a 404 .. the shared item does not exist online ... perhaps a broken 'Add shortcut to My files' link in the account holders directory?
			if ((exception.httpStatusCode == 403) || (exception.httpStatusCode == 404)) {
				// The API call returned a 404 error response
				if (debugLogging) {addLogEntry("onlineParentData = onlineParentOneDriveApiInstance.getPathDetailsById(parentDriveId, parentObjectId); generated a 404 - shared folder path does not exist online", ["debug"]);}
				string errorMessage = format("WARNING: The OneDrive Shared Folder link target '%s' cannot be found online using the provided online data.", onedriveJSONItem["name"].str);
				// detail what this 404 error response means
				addLogEntry();
				addLogEntry(errorMessage);
				addLogEntry("WARNING: This is potentially a broken online OneDrive Shared Folder link or you no longer have access to it. Please correct this error online.");
				addLogEntry();
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				onlineParentOneDriveApiInstance.releaseCurlEngine();
				onlineParentOneDriveApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
				
				// we have to return at this point
				return;
			} else {
				// Catch all other errors
				// Display what the error is
				// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				onlineParentOneDriveApiInstance.releaseCurlEngine();
				onlineParentOneDriveApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
				
				// If we get an error, we cannot do much else
				return;
			}
		}
		
		// Create a 'root' DB Tie Record for a Shared Folder from the parent folder JSON data
		// - This maps the Shared Folder 'driveId' with the parent folder where the shared folder exists, so we can call the parent folder to query for changes to this Shared Folder
		createDatabaseRootTieRecordForOnlineSharedFolder(onlineParentData, relocatedFolderDriveId, relocatedFolderParentId);
		
		// Log that we are created the Shared Folder Tie record now
		if (debugLogging) {addLogEntry("Creating the Shared Folder DB Tie Record that binds the 'root' record to the 'shared folder'" , ["debug"]);}
		
		// Make an item from the online JSON data
		sharedFolderDatabaseTie = makeItem(onlineParentData);
		// Ensure we use our online name, as we may have renamed the folder in our location
		sharedFolderDatabaseTie.name = onedriveJSONItem["name"].str; // use this as the name .. this is the name of the folder online in our OneDrive account, not the online parent name
		
		// Is sharedFolderDatabaseTie.driveId empty?
		if (sharedFolderDatabaseTie.driveId.empty) {
			// This cannot be empty - set to the correct reference for the Shared Folder DB Tie record
			if (debugLogging) {addLogEntry("The Shared Folder DB Tie record entry for 'driveId' is empty ... correcting it" , ["debug"]);}
			sharedFolderDatabaseTie.driveId = onlineParentData["parentReference"]["driveId"].str;
		}
		
		// Ensure 'parentId' is not empty, except for Personal Accounts
		if (appConfig.accountType != "personal") {
			// Is sharedFolderDatabaseTie.parentId.empty?
			if (sharedFolderDatabaseTie.parentId.empty) {
				// This cannot be empty - set to the correct reference for the Shared Folder DB Tie record
				if (debugLogging) {addLogEntry("The Shared Folder DB Tie record entry for 'parentId' is empty ... correcting it" , ["debug"]);}
				sharedFolderDatabaseTie.parentId = onlineParentData["id"].str;
			}
		} else {
			// The database Tie Record for Personal Accounts must be empty .. no change, leave 'parentId' empty
		}
		
		// If a user has added the 'whole' SharePoint Document Library, then the DB Shared Folder Tie Record and 'root' record are the 'same'
		if ((isItemRoot(onlineParentData)) && (onlineParentData["parentReference"]["driveType"].str == "documentLibrary")) {
			// Yes this is a DocumentLibrary 'root' object
			if (debugLogging) {
				addLogEntry("Updating Shared Folder DB Tie record entry with correct values as this is a 'root' object as it is a SharePoint Library Root Object" , ["debug"]);
				addLogEntry(" sharedFolderDatabaseTie.parentId = null", ["debug"]);
				addLogEntry(" sharedFolderDatabaseTie.type = ItemType.root", ["debug"]);
			}
			sharedFolderDatabaseTie.parentId = null;
			sharedFolderDatabaseTie.type = ItemType.root;
		}
		
		// Personal Account Shared Folder Handling 
		if (appConfig.accountType == "personal") {
			// Yes this is a personal account
			if (debugLogging) {
				addLogEntry("Updating Shared Folder DB Tie record entry with correct type value as this as it is a Personal Shared Folder Object" , ["debug"]);
				addLogEntry(" sharedFolderDatabaseTie.type = ItemType.dir", ["debug"]);
			}
			sharedFolderDatabaseTie.type = ItemType.dir;
		}
		
		// Issue #3115 - Validate sharedFolderDatabaseTie.driveId length
		// What account type is this?
		if (appConfig.accountType == "personal") {
			// Issue #3336 - Convert driveId to lowercase before any test
			sharedFolderDatabaseTie.driveId = transformToLowerCase(sharedFolderDatabaseTie.driveId);
			
			// Test sharedFolderDatabaseTie.driveId length and validation if the sharedFolderDatabaseTie.driveId we are testing is not equal to appConfig.defaultDriveId
			if (sharedFolderDatabaseTie.driveId != appConfig.defaultDriveId) {
				sharedFolderDatabaseTie.driveId = testProvidedDriveIdForLengthIssue(sharedFolderDatabaseTie.driveId);
			}
		}
				
		// Log action
		addLogEntry("Creating|Updating a DB Tie Record for this Shared Folder from the online parental data: " ~ sharedFolderDatabaseTie.name, ["debug"]);
		addLogEntry("Shared Folder DB Tie Record data: " ~ to!string(sharedFolderDatabaseTie), ["debug"]);
		
		// Save item
		itemDB.upsert(sharedFolderDatabaseTie);
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		onlineParentOneDriveApiInstance.releaseCurlEngine();
		onlineParentOneDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}		
	}
	
	// If the JSON item IS in the database, this will be an update to an existing in-sync item
	void applyPotentiallyChangedItem(Item existingDatabaseItem, string existingItemPath, Item changedOneDriveItem, string changedItemPath, JSONValue onedriveJSONItem) {
	
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
				
		// If we are moving the item, we do not need to download it again
		bool itemWasMoved = false;
		
		// Do we need to actually update the database with the details that were provided by the OneDrive API?
		// Calculate these time items from the provided items
		SysTime existingItemModifiedTime = existingDatabaseItem.mtime;
		existingItemModifiedTime.fracSecs = Duration.zero;
		SysTime changedOneDriveItemModifiedTime = changedOneDriveItem.mtime;
		changedOneDriveItemModifiedTime.fracSecs = Duration.zero;
		
		// Did the eTag change?
		if (existingDatabaseItem.eTag != changedOneDriveItem.eTag) {
			// The eTag has changed to what we previously cached
			if (existingItemPath != changedItemPath) {
				// Log that we are changing / moving an item to a new name
				addLogEntry("Moving " ~ existingItemPath ~ " to " ~ changedItemPath);
				// Is the destination path empty .. or does something exist at that location?
				if (exists(changedItemPath)) {
					// Destination we are moving to exists ... 
					Item changedLocalItem;
					// Query DB for this changed item in specified path that exists and see if it is in-sync
					if (itemDB.selectByPath(changedItemPath, changedOneDriveItem.driveId, changedLocalItem)) {
						// The 'changedItemPath' is in the database
						string itemSource = "database";
						if (isItemSynced(changedLocalItem, changedItemPath, itemSource)) {
							// The destination item is in-sync
							if (verboseLogging) {addLogEntry("Destination is in sync and will be overwritten", ["verbose"]);}
						} else {
							// The destination item is different
							if (verboseLogging) {addLogEntry("The destination is occupied with a different item, renaming the conflicting file...", ["verbose"]);}
							// If local data protection is configured (bypassDataPreservation = false), safeBackup the local file, passing in if we are performing a --dry-run or not
							// In case the renamed path is needed
							string renamedPath;
							safeBackup(changedItemPath, dryRun, bypassDataPreservation, renamedPath);
						}
					} else {
						// The to be overwritten item is not already in the itemdb, so it should saved to avoid data loss
						if (verboseLogging) {addLogEntry("The destination is occupied by an existing un-synced file, renaming the conflicting file...", ["verbose"]);}
						// If local data protection is configured (bypassDataPreservation = false), safeBackup the local file, passing in if we are performing a --dry-run or not
						// In case the renamed path is needed
						string renamedPath;
						safeBackup(changedItemPath, dryRun, bypassDataPreservation, renamedPath);
					}
				}
				
				// Try and rename path, catch any exception generated
				try {
					// If we are in a --dry-run situation? , the actual rename did not occur - but we need to track like it did
					if(!dryRun) {
						// Rename this item, passing in if we are performing a --dry-run or not
						safeRename(existingItemPath, changedItemPath, dryRun);
					
						// Flag that the item was moved | renamed
						itemWasMoved = true;
					
						// If the item is a file, make sure that the local timestamp now is the same as the timestamp online
						// Otherwise when we do the DB check, the move on the file system, the file technically has a newer timestamp
						// which is 'correct' .. but we need to report locally the online timestamp here as the move was made online
						if (changedOneDriveItem.type == ItemType.file) {
							// Set the timestamp, logging and error handling done within function
							setLocalPathTimestamp(dryRun, changedItemPath, changedOneDriveItem.mtime);
						}
					} else {
						// --dry-run situation - the actual rename did not occur - but we need to track like it did
						// Track this as a faked id item
						idsFaked ~= [changedOneDriveItem.driveId, changedOneDriveItem.id];
						// We also need to track that we did not rename this path
						pathsRenamed ~= [existingItemPath];
					}
				} catch (FileException e) {
					// display the error message
					displayFileSystemErrorMessage(e.msg, thisFunctionName);
				}
			}
			
			// What sort of changed item is this?
			// Is it a file or remote file, and we did not move it ..
			if (((changedOneDriveItem.type == ItemType.file) && (!itemWasMoved)) || (((changedOneDriveItem.type == ItemType.remote) && (changedOneDriveItem.remoteType == ItemType.file)) && (!itemWasMoved))) {
				// The eTag is notorious for being 'changed' online by some backend Microsoft process
				if (existingDatabaseItem.quickXorHash != changedOneDriveItem.quickXorHash) {
					// Add to the items to download array for processing - the file hash we previously recorded is not the same as online
					fileJSONItemsToDownload ~= onedriveJSONItem;
				} else {
					// If the timestamp is different, or we are running a client operational mode that does not support /delta queries - we have to update the DB with the details from OneDrive
					// Unfortunately because of the consequence of National Cloud Deployments not supporting /delta queries, the application uses the local database to flag what is out-of-date / track changes
					// This means that the constant disk writing to the database fix implemented with https://github.com/abraunegg/onedrive/pull/2004 cannot be utilised when using these operational modes
					// as all records are touched / updated when performing the OneDrive sync operations. The impacted operational modes are:
					// - National Cloud Deployments do not support /delta as a query
					// - When using --single-directory
					// - When using --download-only --cleanup-local-files
				
					// Is the last modified timestamp in the DB the same as the API data or are we running an operational mode where we simulated the /delta response?
					if ((existingItemModifiedTime != changedOneDriveItemModifiedTime) || (generateSimulatedDeltaResponse)) {
						// Save this item in the database
						
						// Issue #3115 - Personal Account Shared Folder
						// What account type is this?
						if (appConfig.accountType == "personal") {
							// Is this a 'remote' DB record
							if (changedOneDriveItem.type == ItemType.remote) {
								// Issue #3136, #3139 #3143
								// Fetch the actual online record for this item
								// This returns the actual OneDrive Personal driveId value and is 15 character checked
								string actualOnlineDriveId = testProvidedDriveIdForLengthIssue(fetchRealOnlineDriveIdentifier(changedOneDriveItem.remoteDriveId));
								changedOneDriveItem.remoteDriveId = actualOnlineDriveId;
							}
						}
						
						// Add to the local database
						if (debugLogging) {addLogEntry("Adding changed OneDrive Item to database: " ~ to!string(changedOneDriveItem), ["debug"]);}
						itemDB.upsert(changedOneDriveItem);
					}
				}
			} else {
				// Save this item in the database
				saveItem(onedriveJSONItem);
				
				// If the 'Add shortcut to My files' link was the item that was actually renamed .. we have to update our DB records
				if (changedOneDriveItem.type == ItemType.remote) {
					// Select remote item data from the database
					Item existingRemoteDbItem;
					itemDB.selectById(changedOneDriveItem.remoteDriveId, changedOneDriveItem.remoteId, existingRemoteDbItem);
					// Update the 'name' in existingRemoteDbItem and save it back to the database
					// This is the local name stored on disk that was just 'moved'
					existingRemoteDbItem.name = changedOneDriveItem.name;
					itemDB.upsert(existingRemoteDbItem);
				}
			}
		} else {
			// The existingDatabaseItem.eTag == changedOneDriveItem.eTag .. nothing has changed eTag wise
			
			// If the timestamp is different, or we are running a client operational mode that does not support /delta queries - we have to update the DB with the details from OneDrive
			// Unfortunately because of the consequence of National Cloud Deployments not supporting /delta queries, the application uses the local database to flag what is out-of-date / track changes
			// This means that the constant disk writing to the database fix implemented with https://github.com/abraunegg/onedrive/pull/2004 cannot be utilised when using these operational modes
			// as all records are touched / updated when performing the OneDrive sync operations. The impacted operational modes are:
			// - National Cloud Deployments do not support /delta as a query
			// - When using --single-directory
			// - When using --download-only --cleanup-local-files
		
			// Is the last modified timestamp in the DB the same as the API data or are we running an operational mode where we simulated the /delta response?
			if ((existingItemModifiedTime != changedOneDriveItemModifiedTime) || (generateSimulatedDeltaResponse)) {
				// Database update needed for this item because our local record is out-of-date
				
				// Issue #3115 - Personal Account Shared Folder
				// What account type is this?
				if (appConfig.accountType == "personal") {
					// Is this a 'remote' DB record
					if (changedOneDriveItem.type == ItemType.remote) {
						// Issue #3136, #3139 #3143
						// Fetch the actual online record for this item
						// This returns the actual OneDrive Personal driveId value and is 15 character checked
						string actualOnlineDriveId = testProvidedDriveIdForLengthIssue(fetchRealOnlineDriveIdentifier(changedOneDriveItem.remoteDriveId));
						changedOneDriveItem.remoteDriveId = actualOnlineDriveId;
					}
				}
				
				// Add to the local database
				if (debugLogging) {addLogEntry("Adding changed OneDrive Item to database: " ~ to!string(changedOneDriveItem), ["debug"]);}
				itemDB.upsert(changedOneDriveItem);
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Download new/changed file items as identified
	void downloadOneDriveItems() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// Lets deal with all the JSON items that need to be downloaded in a batch process
		size_t batchSize = to!int(appConfig.getValueLong("threads"));
		long batchCount = (fileJSONItemsToDownload.length + batchSize - 1) / batchSize;
		long batchesProcessed = 0;
		
		// Transfer order
		string transferOrder = appConfig.getValueString("transfer_order");
		
		// Has the user configured to specify the transfer order of files?
		if (transferOrder != "default") {
			// If we have more than 1 item to download, sort the items
			if (count(fileJSONItemsToDownload) > 1) {
			
				// Perform sorting based on transferOrder
				if (transferOrder == "size_asc") {
					fileJSONItemsToDownload.sort!((a, b) => a["size"].integer < b["size"].integer); // sort the array by ascending size
				} else if (transferOrder == "size_dsc") {
					fileJSONItemsToDownload.sort!((a, b) => a["size"].integer > b["size"].integer); // sort the array by descending size
				} else if (transferOrder == "name_asc") {
					fileJSONItemsToDownload.sort!((a, b) => a["name"].str < b["name"].str); // sort the array by ascending name
				} else if (transferOrder == "name_dsc") {
					fileJSONItemsToDownload.sort!((a, b) => a["name"].str > b["name"].str); // sort the array by descending name
				}
			}
		}
		
		// Process fileJSONItemsToDownload
		foreach (chunk; fileJSONItemsToDownload.chunks(batchSize)) {
			// send an array containing 'appConfig.getValueLong("threads")' JSON items to download
			downloadOneDriveItemsInParallel(chunk);
		}
		
		// For this set of items, perform a DB PASSIVE checkpoint
		itemDB.performCheckpoint("PASSIVE");
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Download items in parallel
	void downloadOneDriveItemsInParallel(JSONValue[] array) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// This function received an array of JSON items to download, the number of elements based on appConfig.getValueLong("threads")
		foreach (i, onedriveJSONItem; processPool.parallel(array)) {
			// Take each JSON item and download it
			downloadFileItem(onedriveJSONItem);
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Perform the actual download of an object from OneDrive
	void downloadFileItem(JSONValue onedriveJSONItem, bool ignoreDataPreservationCheck = false, long resumeOffset = 0) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Function variables		
		bool downloadFailed = false;
		string OneDriveFileXORHash;
		string OneDriveFileSHA256Hash;
		long jsonFileSize = 0;
		Item databaseItem;
		bool fileFoundInDB = false;
		
		// Create a JSONValue to store the online hash for resumable file checking
		JSONValue onlineHash;
		
		// Capture what time this download started
		SysTime downloadStartTime = Clock.currTime();
		
		// Download item specifics
		string downloadItemId = onedriveJSONItem["id"].str;
		string downloadItemName = onedriveJSONItem["name"].str;
		string downloadDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
		string downloadParentId = onedriveJSONItem["parentReference"]["id"].str;
		
		// Calculate this items path
		string newItemPath = computeItemPath(downloadDriveId, downloadParentId) ~ "/" ~ downloadItemName;
		if (debugLogging) {addLogEntry("JSON Item calculated full path for download is: " ~ newItemPath, ["debug"]);}
		
		// Is the item reported as Malware ?
		if (isMalware(onedriveJSONItem)){
			// OneDrive reports that this file is malware
			addLogEntry("ERROR: MALWARE DETECTED IN FILE - DOWNLOAD SKIPPED: " ~ newItemPath, ["info", "notify"]);
			downloadFailed = true;
		} else {
			// Grab this file's filesize
			if (hasFileSize(onedriveJSONItem)) {
				// Use the configured filesize as reported by OneDrive
				jsonFileSize = onedriveJSONItem["size"].integer;
			} else {
				// filesize missing
				if (debugLogging) {addLogEntry("ERROR: onedriveJSONItem['size'] is missing", ["debug"]);}
			}
			
			// Configure the hashes for comparison post download
			if (hasHashes(onedriveJSONItem)) {
				// File details returned hash details
				// QuickXorHash
				if (hasQuickXorHash(onedriveJSONItem)) {
					// Use the provided quickXorHash as reported by OneDrive
					if (onedriveJSONItem["file"]["hashes"]["quickXorHash"].str != "") {
						OneDriveFileXORHash = onedriveJSONItem["file"]["hashes"]["quickXorHash"].str;
					}
					// Assign to JSONValue as object for resumable file checking
					onlineHash = JSONValue([
						"quickXorHash": JSONValue(OneDriveFileXORHash)
					]);
				} else {
					// Fallback: Check for SHA256Hash
					if (hasSHA256Hash(onedriveJSONItem)) {
						// Use the provided sha256Hash as reported by OneDrive
						if (onedriveJSONItem["file"]["hashes"]["sha256Hash"].str != "") {
							OneDriveFileSHA256Hash = onedriveJSONItem["file"]["hashes"]["sha256Hash"].str;
						}
						// Assign to JSONValue as object for resumable file checking
						onlineHash = JSONValue([
							"sha256Hash": JSONValue(OneDriveFileSHA256Hash)
						]);
					}
				}
			} else {
				// file hash data missing
				if (debugLogging) {addLogEntry("ERROR: onedriveJSONItem['file']['hashes'] is missing - unable to compare file hash after download to verify integrity of the downloaded file", ["debug"]);}
				// Assign to JSONValue as object for resumable file checking
				onlineHash = JSONValue([
							"hashMissing": JSONValue("none")
						]);
			}
		
			// Does the file already exist in the path locally?
			if (exists(newItemPath)) {
				// To accommodate forcing the download of a file, post upload to Microsoft OneDrive, we need to ignore the checking of hashes and making a safe backup
				if (!ignoreDataPreservationCheck) {
			
					// file exists locally already
					foreach (driveId; onlineDriveDetails.keys) {
						if (itemDB.selectByPath(newItemPath, driveId, databaseItem)) {
							fileFoundInDB = true;
							break;
						}
					}
					
					// Log the DB details
					if (debugLogging) {addLogEntry("File to download exists locally and this is the DB record: " ~ to!string(databaseItem), ["debug"]);}
					
					// Does the DB (what we think is in sync) hash match the existing local file hash?
					if (!testFileHash(newItemPath, databaseItem)) {
						// local file is different to what we know to be true
						addLogEntry("The local file to replace (" ~ newItemPath ~ ") has been modified locally since the last download. Renaming it to avoid potential local data loss.");
						// If local data protection is configured (bypassDataPreservation = false), safeBackup the local file, passing in if we are performing a --dry-run or not
						// In case the renamed path is needed
						string renamedPath;
						safeBackup(newItemPath, dryRun, bypassDataPreservation, renamedPath);
					}
				}
			}
			
			// Is there enough free space locally to download the file
			// - We can use '.' here as we change the current working directory to the configured 'sync_dir'
			long localActualFreeSpace = to!long(getAvailableDiskSpace("."));
			// So that we are not responsible in making the disk 100% full if we can download the file, compare the current available space against the reservation set and file size
			// The reservation value is user configurable in the config file, 50MB by default
			long freeSpaceReservation = appConfig.getValueLong("space_reservation");
			// debug output
			if (debugLogging) {
				addLogEntry("Local Disk Space Actual: " ~ to!string(localActualFreeSpace), ["debug"]);
				addLogEntry("Free Space Reservation:  " ~ to!string(freeSpaceReservation), ["debug"]);
				addLogEntry("File Size to Download:   " ~ to!string(jsonFileSize), ["debug"]);
			}
			
			// Calculate if we can actually download file - is there enough free space?
			if ((localActualFreeSpace < freeSpaceReservation) || (jsonFileSize > localActualFreeSpace)) {
				// localActualFreeSpace is less than freeSpaceReservation .. insufficient free space
				// jsonFileSize is greater than localActualFreeSpace .. insufficient free space
				addLogEntry("Downloading file: " ~ newItemPath ~ " ... failed!", ["info", "notify"]);
				addLogEntry("Insufficient local disk space to download file");
				downloadFailed = true;
			} else {
				// If we are in a --dry-run situation - if not, actually perform the download
				if (!dryRun) {
					// Attempt to download the file as there is enough free space locally
					OneDriveApi downloadFileOneDriveApiInstance;
					
					try {	
						// Initialise API instance
						downloadFileOneDriveApiInstance = new OneDriveApi(appConfig);
						downloadFileOneDriveApiInstance.initialise();
						
						// OneDrive Business Shared Files - update the driveId where to get the file from
						if (isItemRemote(onedriveJSONItem)) {
							downloadDriveId = onedriveJSONItem["remoteItem"]["parentReference"]["driveId"].str;
						}
						
						// Perform the download with any applicable set offset
						downloadFileOneDriveApiInstance.downloadById(downloadDriveId, downloadItemId, newItemPath, jsonFileSize, onlineHash, resumeOffset);
						
						// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
						downloadFileOneDriveApiInstance.releaseCurlEngine();
						downloadFileOneDriveApiInstance = null;
						// Perform Garbage Collection
						GC.collect();
						
					} catch (OneDriveException exception) {
						if (debugLogging) {addLogEntry("downloadFileOneDriveApiInstance.downloadById(downloadDriveId, downloadItemId, newItemPath, jsonFileSize, onlineHash, resumeOffset); generated a OneDriveException", ["debug"]);}
						
						// HTTP request returned status code 403
						if ((exception.httpStatusCode == 403) && (appConfig.getValueBool("sync_business_shared_files"))) {
							// We attempted to download a file, that was shared with us, but this was shared with us as read-only and no download permission
							addLogEntry("Unable to download this file as this was shared as read-only without download permission: " ~ newItemPath);
							downloadFailed = true;
						} else {
							// Default operation if not a 403 error
							// - 408,429,503,504 errors are handled as a retry within downloadFileOneDriveApiInstance
							// Display what the error is
							displayOneDriveErrorMessage(exception.msg, thisFunctionName);
						}
					} catch (FileException e) {
						// There was a file system error
						// display the error message
						displayFileSystemErrorMessage(e.msg, thisFunctionName);
						downloadFailed = true;
					} catch (ErrnoException e) {
						// There was a file system error
						// display the error message
						displayFileSystemErrorMessage(e.msg, thisFunctionName);
						downloadFailed = true;
					}
				
					// If we get to this point, something was downloaded .. does it match what we expected?
					// Does it still exist?
					if (exists(newItemPath)) {
						// When downloading some files from SharePoint, the OneDrive API reports one file size, 
						// but the SharePoint HTTP Server sends a totally different byte count for the same file
						// we have implemented --disable-download-validation to disable these checks
						
						// Regardless of --disable-download-validation we still need to set the file timestamp correctly
						// Get the mtime from the JSON data
						SysTime itemModifiedTime;
						string lastModifiedTimestamp;
						if (isItemRemote(onedriveJSONItem)) {
							// remote file item
							lastModifiedTimestamp = strip(onedriveJSONItem["remoteItem"]["fileSystemInfo"]["lastModifiedDateTime"].str);
							// is lastModifiedTimestamp valid?
							if (isValidUTCDateTime(lastModifiedTimestamp)) {
								// string is a valid timestamp
								itemModifiedTime = SysTime.fromISOExtString(lastModifiedTimestamp);
							} else {
								// invalid timestamp from JSON file
								addLogEntry("WARNING: Invalid timestamp provided by the Microsoft OneDrive API: " ~ lastModifiedTimestamp);
								// Set mtime to Clock.currTime(UTC()) given that the time in the JSON should be a UTC timestamp
								itemModifiedTime = Clock.currTime(UTC());
							}
						} else {
							// not a remote item
							lastModifiedTimestamp = strip(onedriveJSONItem["fileSystemInfo"]["lastModifiedDateTime"].str);
							// is lastModifiedTimestamp valid?
							if (isValidUTCDateTime(lastModifiedTimestamp)) {
								// string is a valid timestamp
								itemModifiedTime = SysTime.fromISOExtString(lastModifiedTimestamp);
							} else {
								// invalid timestamp from JSON file
								addLogEntry("WARNING: Invalid timestamp provided by the Microsoft OneDrive API: " ~ lastModifiedTimestamp);
								// Set mtime to Clock.currTime(UTC()) given that the time in the JSON should be a UTC timestamp
								itemModifiedTime = Clock.currTime(UTC());
							}
						}
						
						// Did the user configure --disable-download-validation ?
						if (!disableDownloadValidation) {
							// A 'file' was downloaded - does what we downloaded = reported jsonFileSize or if there is some sort of funky local disk compression going on
							// Does the file hash OneDrive reports match what we have locally?
							string onlineFileHash;
							string downloadedFileHash;
							long downloadFileSize = getSize(newItemPath);
							
							if (!OneDriveFileXORHash.empty) {
								onlineFileHash = OneDriveFileXORHash;
								// Calculate the QuickXOHash for this file
								downloadedFileHash = computeQuickXorHash(newItemPath);
							} else {
								onlineFileHash = OneDriveFileSHA256Hash;
								// Fallback: Calculate the SHA256 Hash for this file
								downloadedFileHash = computeSHA256Hash(newItemPath);
							}
							
							if ((downloadFileSize == jsonFileSize) && (downloadedFileHash == onlineFileHash)) {
								// Downloaded file matches size and hash
								if (debugLogging) {addLogEntry("Downloaded file matches reported size and reported file hash", ["debug"]);}
								
								// Set the timestamp, logging and error handling done within function
								setLocalPathTimestamp(dryRun, newItemPath, itemModifiedTime);
							} else {
								// Downloaded file does not match size or hash .. which is it?
								bool downloadValueMismatch = false;
								
								// Size error?
								if (downloadFileSize != jsonFileSize) {
									// downloaded file size does not match
									downloadValueMismatch = true;
									if (debugLogging) {
										addLogEntry("Actual file size on disk:   " ~ to!string(downloadFileSize), ["debug"]);
										addLogEntry("OneDrive API reported size: " ~ to!string(jsonFileSize), ["debug"]);
									}
									addLogEntry("ERROR: File download size mismatch. Increase logging verbosity to determine why.");
								}
								
								// Hash Error?
								if (downloadedFileHash != onlineFileHash) {
									// downloaded file hash does not match
									downloadValueMismatch = true;
									if (debugLogging) {
										addLogEntry("Actual local file hash:     " ~ downloadedFileHash, ["debug"]);
										addLogEntry("OneDrive API reported hash: " ~ onlineFileHash, ["debug"]);
									}
									addLogEntry("ERROR: File download hash mismatch. Increase logging verbosity to determine why.");
								}
								
								// .heic data loss check
								// - https://github.com/abraunegg/onedrive/issues/2471
								// - https://github.com/OneDrive/onedrive-api-docs/issues/1532
								// - https://github.com/OneDrive/onedrive-api-docs/issues/1723
								if (downloadValueMismatch && (toLower(extension(newItemPath)) == ".heic")) {
									// Need to display a message to the user that they have experienced data loss
									addLogEntry("DATA-LOSS: File downloaded has experienced data loss due to a Microsoft OneDrive API bug. DO NOT DELETE THIS FILE ONLINE: " ~ newItemPath, ["info", "notify"]);
									if (verboseLogging) {addLogEntry("           Please read https://github.com/OneDrive/onedrive-api-docs/issues/1723 for more details.", ["verbose"]);}
								}
								
								// Add some workaround messaging for SharePoint
								if (appConfig.accountType == "documentLibrary"){
									// It has been seen where SharePoint / OneDrive API reports one size via the JSON 
									// but the content length and file size written to disk is totally different - example:
									// From JSON:         "size": 17133
									// From HTTPS Server: < Content-Length: 19340
									// with no logical reason for the difference, except for a 302 redirect before file download
									addLogEntry("INFO: It is most likely that a SharePoint OneDrive API issue is the root cause. Add --disable-download-validation to work around this issue but downloaded data integrity cannot be guaranteed.");
								} else {
									// other account types
									addLogEntry("INFO: Potentially add --disable-download-validation to work around this issue but downloaded data integrity cannot be guaranteed.");
								}
								
								// If the computed hash does not equal provided online hash, consider this a failed download
								if (downloadedFileHash != onlineFileHash) {
									// We do not want this local file to remain on the local file system as it failed the integrity checks
									addLogEntry("Removing local file " ~ newItemPath ~ " due to failed integrity checks");
									if (!dryRun) {
										safeRemove(newItemPath);
									}
									
									// Was this item previously in-sync with the local system?
									// We previously searched for the file in the DB, we need to use that record
									if (fileFoundInDB) {
										// Purge DB record so that the deleted local file does not cause an online deletion
										// In a --dry-run scenario, this is being done against a DB copy
										addLogEntry("Removing DB record due to failed integrity checks");
										itemDB.deleteById(databaseItem.driveId, databaseItem.id);
									}
									
									// Flag that the download failed
									downloadFailed = true;
								}
							}
						} else {
							// Download validation checks were disabled
							if (debugLogging) {addLogEntry("Downloaded file validation disabled due to --disable-download-validation", ["debug"]);}
							if (verboseLogging) {addLogEntry("WARNING: Skipping download integrity check for: " ~ newItemPath, ["verbose"]);}
							
							// Whilst the download integrity checks were disabled, we still have to set the correct timestamp on the file
							// Set the timestamp, logging and error handling done within function
							setLocalPathTimestamp(dryRun, newItemPath, itemModifiedTime);
							
							// Azure Information Protection (AIP) protected files potentially have missing data and/or inconsistent data
							if (appConfig.accountType != "personal") {
								// AIP Protected Files cause issues here, as the online size & hash are not what has been downloaded
								// There is ZERO way to determine if this is an AIP protected file either from the JSON data
								
								// Calculate the local file hash and get the local file size
								string localFileHash = computeQuickXorHash(newItemPath);
								long downloadFileSize = getSize(newItemPath);
								
								if ((OneDriveFileXORHash != localFileHash) && (jsonFileSize != downloadFileSize)) {
								
									// High potential to be an AIP protected file given the following scenario
									// Business | SharePoint Account Type (not a personal account)
									// --disable-download-validation is being used .. meaning the user has specifically configured this due the Microsoft SharePoint Enrichment Feature (bug)
									// The file downloaded but the XOR hash and file size locally is not as per the provided JSON - both are different
									//
									// Update the 'onedriveJSONItem' JSON data with the local values ..... 
									if (debugLogging) {
										string aipLogMessage = format("POTENTIAL AIP FILE (Issue 3070) - Changing the source JSON data provided by Graph API to use actual on-disk values (quickXorHash,size): %s", newItemPath);
										addLogEntry(aipLogMessage, ["debug"]);
										addLogEntry(" - Online XOR   : " ~ to!string(OneDriveFileXORHash), ["debug"]);
										addLogEntry(" - Online Size  : " ~ to!string(jsonFileSize), ["debug"]);
										addLogEntry(" - Local XOR    : " ~ to!string(computeQuickXorHash(newItemPath)), ["debug"]);
										addLogEntry(" - Local Size   : " ~ to!string(getSize(newItemPath)), ["debug"]);
									}
									
									// Make the change in the JSON using local values
									onedriveJSONItem["file"]["hashes"]["quickXorHash"] = localFileHash;
									onedriveJSONItem["size"] = downloadFileSize;
								}
							}
						}	// end of (!disableDownloadValidation)
					} else {
						// File does not exist locally
						addLogEntry("ERROR: File failed to download. Increase logging verbosity to determine why.");
						// Was this item previously in-sync with the local system?
						// We previously searched for the file in the DB, we need to use that record
						if (fileFoundInDB) {
							// Purge DB record so that the deleted local file does not cause an online deletion
							// In a --dry-run scenario, this is being done against a DB copy
							addLogEntry("Removing existing DB record due to failed file download.");
							itemDB.deleteById(databaseItem.driveId, databaseItem.id);
						}
						
						// Flag that the download failed
						downloadFailed = true;
					}
				}
			}
			
			// File should have been downloaded
			if (!downloadFailed) {
				// Download did not fail
				addLogEntry("Downloading file: " ~ newItemPath ~ " ... done", fileTransferNotifications());
				
				// As no download failure, calculate transfer metrics in a consistent manner
				displayTransferMetrics(newItemPath, jsonFileSize, downloadStartTime, Clock.currTime());
				
				// Save this item into the database
				saveItem(onedriveJSONItem);
				
				// If we are in a --dry-run situation - if we are, we need to track that we faked the download
				if (dryRun) {
					// track that we 'faked it'
					idsFaked ~= [downloadDriveId, downloadItemId];
				}
				
				// If, the initial download failed, but, during the 'Performing a last examination of the most recent online data within Microsoft OneDrive' Process
				// the file downloads without issue, check if the path is in 'fileDownloadFailures' and if this is in this array, remove this entry as it is technically no longer valid to be in there
				if (canFind(fileDownloadFailures, newItemPath)) {
					// Remove 'newItemPath' from 'fileDownloadFailures' as this is no longer a failed download
					fileDownloadFailures = fileDownloadFailures.filter!(item => item != newItemPath).array;
				}
				
				// Did the user configure to save xattr data about this file?
				if (appConfig.getValueBool("write_xattr_data")) {
					writeXattrData(newItemPath, onedriveJSONItem);
				}
			} else {
				// Output to the user that the file download failed
				addLogEntry("Downloading file: " ~ newItemPath ~ " ... failed!", ["info", "notify"]);
				
				// Add the path to a list of items that failed to download
				if (!canFind(fileDownloadFailures, newItemPath)) {
					fileDownloadFailures ~= newItemPath; // Add newItemPath if it's not already present
				}
				
				// Since the file download failed:
				// - The file should not exist locally
				// - The download identifiers should not exist in the local database
				if (!exists(newItemPath)) {
					// The local path does not exist
					if (itemDB.idInLocalDatabase(downloadDriveId, downloadItemId)) {
						// Since the path does not exist, but the driveId and itemId exists in the database, when we do the DB consistency check, we will think this file has been 'deleted'
						// The driveId and itemId online exists in our database - it needs to be removed so this does not occur
						addLogEntry("Removing existing DB record due to failed file download.");
						itemDB.deleteById(downloadDriveId, downloadItemId);
					}
				}
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Write xattr data if configured to do so
	void writeXattrData(string filePath, JSONValue onedriveJSONItem) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// We can only set xattr values when not performing a --dry-run operation
		if (!dryRun) {
			// This function will write the following xattr attributes based on the JSON data received from Microsoft onedrive
			// - createdBy using the 'displayName' value
			// - lastModifiedBy using the 'displayName' value
			string createdBy;
			string lastModifiedBy;
			
			// Configure 'createdBy' from the JSON data
			if (hasCreatedByUserDisplayName(onedriveJSONItem)) {
				createdBy = onedriveJSONItem["createdBy"]["user"]["displayName"].str;
			} else {
				// required data not in JSON data
				createdBy = "Unknown";
			}
			
			// Configure 'lastModifiedBy' from the JSON data
			if (hasLastModifiedByUserDisplayName(onedriveJSONItem)) {
				lastModifiedBy = onedriveJSONItem["lastModifiedBy"]["user"]["displayName"].str;
			} else {
				// required data not in JSON data
				lastModifiedBy = "Unknown";
			}
			
			// Set the xattr values, file must exist to set these values
			if (exists(filePath)) {
				setXAttr(filePath, "user.onedrive.createdBy", createdBy);
				setXAttr(filePath, "user.onedrive.lastModifiedBy", lastModifiedBy);
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}	
	}
	
	// Test if the given item is in-sync. Returns true if the given item corresponds to the local one
	bool isItemSynced(Item item, string path, string itemSource) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Due to this function, we need to keep the return <bool value>; code, so that this function operates as efficiently as possible.
		// It is pointless having the entire code run through and performing additional needless checks where it is not required
		// Whilst this means some extra code / duplication in this function, it cannot be helped
		
		if (!exists(path)) {
			if (debugLogging) {addLogEntry("Unable to determine the sync state of this file as it does not exist: " ~ path, ["debug"]);}
			
			// Display function processing time if configured to do so
			if (appConfig.getValueBool("display_processing_time") && debugLogging) {
				// Combine module name & running Function
				displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
			}

			return false;
		}

		// Combine common logic for readability and file check into a single block
		if (item.type == ItemType.file || ((item.type == ItemType.remote) && (item.remoteType == ItemType.file))) {
			// Can we actually read the local file?
			if (!readLocalFile(path)) {
				// Unable to read local file
				addLogEntry("Unable to determine the sync state of this file as it cannot be read (file permissions or file corruption): " ~ path);
				
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
				
				return false;
			}
			
			// Get time values
			SysTime localModifiedTime = timeLastModified(path).toUTC();
			SysTime itemModifiedTime = item.mtime;
			// Reduce time resolution to seconds before comparing
			localModifiedTime.fracSecs = Duration.zero;
			itemModifiedTime.fracSecs = Duration.zero;

			if (localModifiedTime == itemModifiedTime) {
			
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
			
				return true;
			} else {
				// The file has a different timestamp ... is the hash the same meaning no file modification?
				if (verboseLogging) {
					addLogEntry("Local file time discrepancy detected: " ~ path, ["verbose"]);
					addLogEntry("This local file has a different modified time " ~ to!string(localModifiedTime) ~ " (UTC) when compared to " ~ itemSource ~ " modified time " ~ to!string(itemModifiedTime) ~ " (UTC)", ["verbose"]);
				}

				// The file has a different timestamp ... is the hash the same meaning no file modification?
				// Test the file hash as the date / time stamp is different
				// Generating a hash is computationally expensive - we only generate the hash if timestamp was different
				if (testFileHash(path, item)) {
					// The hash is the same .. so we need to fix-up the timestamp depending on where it is wrong
					if (verboseLogging) {addLogEntry("Local item has the same hash value as the item online - correcting the applicable file timestamp", ["verbose"]);}
					// Correction logic based on the configuration and the comparison of timestamps
					if (localModifiedTime > itemModifiedTime) {
						// Local file is newer timestamp wise, but has the same hash .. are we in a --download-only situation?
						if (!appConfig.getValueBool("download_only") && !dryRun) {
							// Not --download-only .. but are we in a --resync scenario?
							if (appConfig.getValueBool("resync")) {
								// --resync was used
								// The source of the out-of-date timestamp was the local item and needs to be corrected ... but why is it newer - indexing application potentially changing the timestamp ?
								if (verboseLogging) {addLogEntry("The source of the incorrect timestamp was the local file - correcting timestamp locally due to --resync", ["verbose"]);}
								// Fix the timestamp, logging and error handling done within function
								setLocalPathTimestamp(dryRun, path, item.mtime);
							} else {
								// The source of the out-of-date timestamp was OneDrive and this needs to be corrected to avoid always generating a hash test if timestamp is different
								if (verboseLogging) {addLogEntry("The source of the incorrect timestamp was OneDrive online - correcting timestamp online", ["verbose"]);}
								// Attempt to update the online date time stamp
								// We need to use the correct driveId and itemId, especially if we are updating a OneDrive Business Shared File timestamp
								if (item.type == ItemType.file) {
									// Not a remote file
									uploadLastModifiedTime(item, item.driveId, item.id, localModifiedTime, item.eTag);
								} else {
									// Remote file, remote values need to be used
									uploadLastModifiedTime(item, item.remoteDriveId, item.remoteId, localModifiedTime, item.eTag);
								}
							}
						} else if (!dryRun) {
							// --download-only is being used ... local file needs to be corrected ... but why is it newer - indexing application potentially changing the timestamp ?
							if (verboseLogging) {addLogEntry("The source of the incorrect timestamp was the local file - correcting timestamp locally due to --download-only", ["verbose"]);}
							// Fix the timestamp, logging and error handling done within function
							setLocalPathTimestamp(dryRun, path, item.mtime);
						}
					} else if (!dryRun) {
						// The source of the out-of-date timestamp was the local file and this needs to be corrected to avoid always generating a hash test if timestamp is different
						if (verboseLogging) {addLogEntry("The source of the incorrect timestamp was the local file - correcting timestamp locally", ["verbose"]);}
						
						// Fix the timestamp, logging and error handling done within function
						setLocalPathTimestamp(dryRun, path, item.mtime);
					}
					
					// Display function processing time if configured to do so
					if (appConfig.getValueBool("display_processing_time") && debugLogging) {
						// Combine module name & running Function
						displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
					}
					
					return false;
				} else {
					// The hash is different so the content of the file has to be different as to what is stored online
					if (verboseLogging) {addLogEntry("The local file has a different hash when compared to " ~ itemSource ~ " file hash", ["verbose"]);}
					
					// Display function processing time if configured to do so
					if (appConfig.getValueBool("display_processing_time") && debugLogging) {
						// Combine module name & running Function
						displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
					}
					
					return false;
				}
			}
		} else if (item.type == ItemType.dir || ((item.type == ItemType.remote) && (item.remoteType == ItemType.dir))) {
			// item is a directory
			
			// Display function processing time if configured to do so
			if (appConfig.getValueBool("display_processing_time") && debugLogging) {
				// Combine module name & running Function
				displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
			}
			
			return true;
		} else {
			// ItemType.unknown or ItemType.none
			// Logically, we might not want to sync these items, but a more nuanced approach may be needed based on application context
			
			// Display function processing time if configured to do so
			if (appConfig.getValueBool("display_processing_time") && debugLogging) {
				// Combine module name & running Function
				displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
			}
			
			return true;
		}
	}
	
	// Get the /delta data using the provided details
	JSONValue getDeltaChangesByItemId(string selectedDriveId, string selectedItemId, string providedDeltaLink, OneDriveApi getDeltaQueryOneDriveApiInstance) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
			
		// Function variables
		JSONValue deltaChangesBundle;
		
		// Get the /delta data for this account | driveId | deltaLink combination
		if (debugLogging) {
			addLogEntry(debugLogBreakType1, ["debug"]);
			addLogEntry("selectedDriveId:   " ~ selectedDriveId, ["debug"]);
			addLogEntry("selectedItemId:    " ~ selectedItemId, ["debug"]);
			addLogEntry("providedDeltaLink: " ~ providedDeltaLink, ["debug"]);
			addLogEntry(debugLogBreakType1, ["debug"]);
		}
		
		try {
			deltaChangesBundle = getDeltaQueryOneDriveApiInstance.getChangesByItemId(selectedDriveId, selectedItemId, providedDeltaLink);
		} catch (OneDriveException exception) {
			// caught an exception
			if (debugLogging) {addLogEntry("getDeltaQueryOneDriveApiInstance.getChangesByItemId(selectedDriveId, selectedItemId, providedDeltaLink) generated a OneDriveException", ["debug"]);}
			
			// get the error message
			auto errorArray = splitLines(exception.msg);
			
			// Error handling operation if not 408,429,503,504 errors
			// - 408,429,503,504 errors are handled as a retry within getDeltaQueryOneDriveApiInstance
			if (exception.httpStatusCode == 410) {
				addLogEntry();
				addLogEntry("WARNING: The OneDrive API responded with an error that indicates the locally stored deltaLink value is invalid");
				// Essentially the 'providedDeltaLink' that we have stored is no longer available ... re-try without the stored deltaLink
				addLogEntry("WARNING: Retrying OneDrive API call without using the locally stored deltaLink value");
				// Configure an empty deltaLink
				if (debugLogging) {addLogEntry("Delta link expired for 'getDeltaQueryOneDriveApiInstance.getChangesByItemId(selectedDriveId, selectedItemId, providedDeltaLink)', setting 'deltaLink = null'", ["debug"]);}
				string emptyDeltaLink = "";
				// retry with empty deltaLink
				deltaChangesBundle = getDeltaQueryOneDriveApiInstance.getChangesByItemId(selectedDriveId, selectedItemId, emptyDeltaLink);
			} else {
				// Display what the error is
				addLogEntry("CODING TO DO: Hitting this failure error output after getting a httpStatusCode != 410 when the API responded the deltaLink was invalid");
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
				deltaChangesBundle = null;
				// Perform Garbage Collection
				GC.collect();
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// Return data
		return deltaChangesBundle;
	}
	
	// If the JSON response is not correct JSON object, exit
	void invalidJSONResponseFromOneDriveAPI() {
		addLogEntry("ERROR: Query of the OneDrive API returned an invalid JSON response");
		// Must force exit here, allow logging to be done
		forceExit();
	}
	
	// Handle an unhandled API error
	void defaultUnhandledHTTPErrorCode(OneDriveException exception) {
		// compute function name
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// display error
		displayOneDriveErrorMessage(exception.msg, thisFunctionName);
		// Must force exit here, allow logging to be done
		forceExit();
	}
	
	// Display the pertinent details of the sync engine
	void displaySyncEngineDetails() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// Display accountType, defaultDriveId, defaultRootId & remainingFreeSpace for verbose logging purposes
		addLogEntry("Application Version:   " ~ appConfig.applicationVersion, ["verbose"]);
		addLogEntry("Account Type:          " ~ appConfig.accountType, ["verbose"]);
		addLogEntry("Default Drive ID:      " ~ appConfig.defaultDriveId, ["verbose"]);
		addLogEntry("Default Root ID:       " ~ appConfig.defaultRootId, ["verbose"]);
		addLogEntry("Microsoft Data Centre: " ~ microsoftDataCentre, ["verbose"]);
	
		// Fetch the details from cachedOnlineDriveData
		DriveDetailsCache cachedOnlineDriveData;
		cachedOnlineDriveData = getDriveDetails(appConfig.defaultDriveId);
	
		// What do we display here for space remaining
		if (cachedOnlineDriveData.quotaRemaining > 0) {
			// Display the actual value
			addLogEntry("Remaining Free Space:  " ~ to!string(byteToGibiByte(cachedOnlineDriveData.quotaRemaining)) ~ " GB (" ~ to!string(cachedOnlineDriveData.quotaRemaining) ~ " bytes)", ["verbose"]);
		} else {
			// zero or non-zero value or restricted
			if (!cachedOnlineDriveData.quotaRestricted){
				addLogEntry("Remaining Free Space:  0 KB", ["verbose"]);
			} else {
				addLogEntry("Remaining Free Space:  Not Available", ["verbose"]);
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Query itemdb.computePath() and catch potential assert when DB consistency issue occurs
	// This function returns what that local physical path should be on the local disk
	string computeItemPath(string thisDriveId, string thisItemId) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// static declare this for this function
		static import core.exception;
		string calculatedPath;
		
		// Issue #3336 - Convert thisDriveId to lowercase before any test
		if (appConfig.accountType == "personal") {
			thisDriveId = transformToLowerCase(thisDriveId);
		}
		
		// What driveID and itemID we trying to calculate the path for
		if (debugLogging) {
			string initialComputeLogMessage = format("Attempting to calculate local filesystem path for '%s' and '%s'", thisDriveId, thisItemId);
			addLogEntry(initialComputeLogMessage, ["debug"]);
			}
		
		// Perform the original calculation of the path using the values provided
		try {
			// The 'itemDB.computePath' will calculate the full path for the combination of provided driveId and itemId values.
			// This function traverses the parent chain of a given item (e.g., folder or file) using stored parent-child relationships 
			// in the database, reconstructing the correct path from the item's root to itself.
			calculatedPath = itemDB.computePath(thisDriveId, thisItemId);
			if (debugLogging) {addLogEntry("Calculated local path = " ~ to!string(calculatedPath), ["debug"]);}
		} catch (core.exception.AssertError) {
			// broken tree in the database, we cant compute the path for this item id, exit
			addLogEntry("ERROR: A database consistency issue has been caught. A --resync is needed to rebuild the database.");
			// Must force exit here, allow logging to be done
			forceExit();
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// return calculated path as string
		return calculatedPath;
	}
	
	// Try and compute the file hash for the given item
	bool testFileHash(string path, Item item) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Due to this function, we need to keep the return <bool value>; code, so that this function operates as efficiently as possible.
		// It is pointless having the entire code run through and performing additional needless checks where it is not required
		// Whilst this means some extra code / duplication in this function, it cannot be helped
		
		// Generate QuickXORHash first before attempting to generate any other type of hash
		if (item.quickXorHash) {
			if (item.quickXorHash == computeQuickXorHash(path)) {
				
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
			
				return true;
			}
		} else if (item.sha256Hash) {
			if (item.sha256Hash == computeSHA256Hash(path)) {
			
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
			
				return true;
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		return false;
	}
	
	// Process items that need to be removed from the local filesystem as they were removed online
	void processDeleteItems() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Has the user configured to use the 'Recycle Bin' locally, for any files that are deleted online?
		if (!appConfig.getValueBool("use_recycle_bin")) {
		
			if (debugLogging) {addLogEntry("Performing filesystem deletion, using reverse order of items to delete", ["debug"]);}
		
			foreach_reverse (i; idsToDelete) {
				Item item;
				string path;
				if (!itemDB.selectById(i[0], i[1], item)) continue; // check if the item is in the db
				// Compute this item path
				path = computeItemPath(i[0], i[1]);
				
				// Log the action if the path exists .. it may of already been removed and this is a legacy array item
				if (exists(path)) {
					if (item.type == ItemType.file) {
						addLogEntry("Trying to delete local file: " ~ path);
					} else {
						addLogEntry("Trying to delete local directory: " ~ path);
					}
				}
				
				// Process the database entry removal. In a --dry-run scenario, this is being done against a DB copy
				itemDB.deleteById(item.driveId, item.id);
				if (item.remoteDriveId != null) {
					// delete the linked remote folder
					itemDB.deleteById(item.remoteDriveId, item.remoteId);
				}
				
				// Add to pathFakeDeletedArray
				// We dont want to try and upload this item again, so we need to track this objects removal
				if (dryRun) {
					// We need to add './' here so that it can be correctly searched to ensure it is not uploaded
					string pathToAdd = "./" ~ path;
					pathFakeDeletedArray ~= pathToAdd;
				}
					
				bool needsRemoval = false;
				if (exists(path)) {
					// path exists on the local system	
					// make sure that the path refers to the correct item
					Item pathItem;
					if (itemDB.selectByPath(path, item.driveId, pathItem)) {
						if (pathItem.id == item.id) {
							needsRemoval = true;
						} else {
							addLogEntry("Skipping local path removal due to 'id' difference!");
						}
					} else {
						// item has disappeared completely
						needsRemoval = true;
					}
				}
				
				if (needsRemoval) {
					// Log the action
					if (item.type == ItemType.file) {
						addLogEntry("Deleting local file: " ~ path, fileTransferNotifications());
					} else {
						addLogEntry("Deleting local directory: " ~ path, fileTransferNotifications());
					}
					
					// Perform the action
					if (!dryRun) {
						if (isFile(path)) {
							remove(path);
						} else {
							try {
								// Remove any children of this path if they still exist
								// Resolve 'Directory not empty' error when deleting local files
								foreach (DirEntry child; dirEntries(path, SpanMode.depth, false)) {
									attrIsDir(child.linkAttributes) ? rmdir(child.name) : remove(child.name);
								}
								// Remove the path now that it is empty of children
								rmdirRecurse(path);
							} catch (FileException e) {
								// display the error message
								displayFileSystemErrorMessage(e.msg, thisFunctionName);
							}
						}
					}
				}
			}
			
		} else {
		
			if (debugLogging) {addLogEntry("Moving online deleted files to configured local Recycle Bin", ["debug"]);}
			
			// Process in normal order, so that the parent, if a folder, gets moved 'first' mirroring how files / folders are deleted in GNOME and KDE
			foreach (i; idsToDelete) {
				Item item;
				string path;
				if (!itemDB.selectById(i[0], i[1], item)) continue; // check if the item is in the db
				// Compute this item path
				path = computeItemPath(i[0], i[1]);
				
				// Log the action if the path exists .. it may of already been removed and this is a legacy array item
				if (exists(path)) {
					if (item.type == ItemType.file) {
						addLogEntry("Trying to move this local file to the configured 'Recycle Bin': " ~ path);
					} else {
						addLogEntry("Trying to move this local directory to the configured 'Recycle Bin': " ~ path);
					}
				}
				
				// Process the database entry removal. In a --dry-run scenario, this is being done against a DB copy
				itemDB.deleteById(item.driveId, item.id);
				if (item.remoteDriveId != null) {
					// delete the linked remote folder
					itemDB.deleteById(item.remoteDriveId, item.remoteId);
				}
				
				// Add to pathFakeDeletedArray
				// We dont want to try and upload this item again, so we need to track this objects removal
				if (dryRun) {
					// We need to add './' here so that it can be correctly searched to ensure it is not uploaded
					string pathToAdd = "./" ~ path;
					pathFakeDeletedArray ~= pathToAdd;
				}
				
				// Local path removal
				bool needsRemoval = false;
				if (exists(path)) {
					// path exists on the local system	
					// make sure that the path refers to the correct item
					Item pathItem;
					if (itemDB.selectByPath(path, item.driveId, pathItem)) {
						if (pathItem.id == item.id) {
							needsRemoval = true;
						} else {
							addLogEntry("Skipping local path removal due to 'id' difference!");
						}
					} else {
						// item has disappeared completely
						needsRemoval = true;
					}
				}
				
				if (needsRemoval) {
					// Log the action
					if (item.type == ItemType.file) {
						addLogEntry("Moving this local file to the configured 'Recycle Bin': " ~ path, fileTransferNotifications());
					} else {
						addLogEntry("Moving this local directory to the configured 'Recycle Bin': " ~ path, fileTransferNotifications());
					}
					
					// Perform the action
					if (!dryRun) {
						// Move the 'path' to the configured recycle bin
						movePathToRecycleBin(path);
					}
				}
			}
		}
		
		if (!dryRun) {
			// Cleanup array memory
			idsToDelete = [];
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}

	// Move to the 'Recycle Bin' rather than a hard delete locally of the online deleted item	
	void movePathToRecycleBin(string path) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// This is a 2 step process
		// 1. Move the file
		//    - If the destination 'name' already exists, the file being moved to the 'Recycle Bin' needs to have a number added to it.
		// 2. Create the metadata about where the file came from
		//    - This is in a specific format:
		//    		[Trash Info]
		//    		Path=/original/absolute/path/to/the/file/or/folder
		//    		DeletionDate=YYYY-MM-DDTHH:MM:SS
		
		// Calculate all the initial paths required
		string computedFullLocalPath = absolutePath(path);
		string fileNameOnly = baseName(path);
		string computedRecycleBinFilePath = appConfig.recycleBinFilePath ~ fileNameOnly;
		string computedRecycleBinInfoPath = appConfig.recycleBinInfoPath ~ fileNameOnly ~ ".trashinfo";
		bool isPathFile = isFile(computedFullLocalPath);
		
		// The 'destination' needs to be unique, but if there is a 'collision' the RecycleBin paths need to be updated to be:
		// - file1.data (1)
		// - file1.data (1).trashinfo
		if (exists(computedRecycleBinFilePath)) {
			// There is an existing file with the same name already in the 'Recycle Bin'
			// - Testing has show that this counter MUST start at 2 to be compatible with FreeDesktop.org Trash Specification ....
			int n = 2;
			
			// We need to split this out
			string nameOnly = stripExtension(fileNameOnly); // "file1"
			string extension = extension(fileNameOnly);     // ".data"
			
			// We need to test for this: nameOnly.n.extension
			while (exists(format(appConfig.recycleBinFilePath ~ nameOnly ~ ".%d." ~ extension, n))) {
				n++;
			}
			
			// Generate newFileNameOnly
			string newFileNameOnly = format(nameOnly ~ ".%d." ~ extension, n);
			
			// UPDATE:
			// - computedRecycleBinFilePath
			// - computedRecycleBinInfoPath
			computedRecycleBinFilePath = appConfig.recycleBinFilePath ~ newFileNameOnly;
			computedRecycleBinInfoPath = appConfig.recycleBinInfoPath ~ newFileNameOnly ~ ".trashinfo";
		}
		
		// Move the file to the 'Recycle Bin' path computedRecycleBinFilePath
		// - DMD has no 'move' specifically, it uses 'rename' to achieve this
		//   https://forum.dlang.org/thread/kwnwrlqtjehldckyfmau@forum.dlang.org
		// Use rename() as Linux is POSIX compliant, we have an atomic operation where at no point in time the 'to' is missing.
		try {
			rename(computedFullLocalPath, computedRecycleBinFilePath);
		} catch (Exception e) {
			// Handle exceptions, e.g., log error
			if (isPathFile) {
				addLogEntry("Move of local file failed for " ~ to!string(path) ~ ": " ~ e.msg, ["error"]);
			} else {
				addLogEntry("Move of local directory failed for " ~ to!string(path) ~ ": " ~ e.msg, ["error"]);
			}
		}
		
		// Generate the 'Recycle Bin' metadata file using computedRecycleBinInfoPath
		auto now = Clock.currTime().toLocalTime();
		string deletionDate = format("%04d-%02d-%02dT%02d:%02d:%02d",now.year, now.month, now.day, now.hour, now.minute, now.second);
		
		// Format the content of the .trashinfo file
		string content = format("[Trash Info]\nPath=%s\nDeletionDate=%s\n", computedFullLocalPath, deletionDate);
		// Write the metadata file
		
		try {
			std.file.write(computedRecycleBinInfoPath, content);
		} catch (Exception e) {
			// Handle exceptions, e.g., log error
			addLogEntry("Writing of .trashinfo metadata file failed for " ~ computedRecycleBinInfoPath ~ ": " ~ e.msg, ["error"]);
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// List items that were deleted online, but, due to --download-only being used, will not be deleted locally
	void listDeletedItems() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// For each id in the idsToDelete array
		foreach_reverse (i; idsToDelete) {
			Item item;
			string path;
			if (!itemDB.selectById(i[0], i[1], item)) continue; // check if the item is in the db
			// Compute this item path
			path = computeItemPath(i[0], i[1]);
			
			// Log the action if the path exists .. it may of already been removed and this is a legacy array item
			if (exists(path)) {
				if (item.type == ItemType.file) {
					if (verboseLogging) {addLogEntry("Skipping local deletion for file " ~ path, ["verbose"]);}
				} else {
					if (verboseLogging) {addLogEntry("Skipping local deletion for directory " ~ path, ["verbose"]);}
				}
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Update the timestamp of an object online
	void uploadLastModifiedTime(Item originItem, string driveId, string id, SysTime mtime, string eTag) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		string itemModifiedTime;
		itemModifiedTime = mtime.toISOExtString();
		JSONValue data = [
			"fileSystemInfo": JSONValue([
				"lastModifiedDateTime": itemModifiedTime
			])
		];
		
		// What eTag value do we use?
		string eTagValue;
		if (appConfig.accountType == "personal") {
			// Nullify the eTag to avoid 412 errors as much as possible
			eTagValue = null;
		} else {
			eTagValue = eTag;
		}
		
		JSONValue response;
		OneDriveApi uploadLastModifiedTimeApiInstance;
		
		// Try and update the online last modified time
		try {
			// Create a new OneDrive API instance
			uploadLastModifiedTimeApiInstance = new OneDriveApi(appConfig);
			uploadLastModifiedTimeApiInstance.initialise();
			// Use this instance
			response = uploadLastModifiedTimeApiInstance.updateById(driveId, id, data, eTagValue);
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			uploadLastModifiedTimeApiInstance.releaseCurlEngine();
			uploadLastModifiedTimeApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			
			// Do we actually save the response?
			// Special case here .. if the DB record item (originItem) is a remote object, thus, if we save the 'response' we will have a DB FOREIGN KEY constraint failed problem
			//  Update 'originItem.mtime' with the correct timestamp
			//  Update 'originItem.size' with the correct size from the response
			//  Update 'originItem.eTag' with the correct eTag from the response
			//  Update 'originItem.cTag' with the correct cTag from the response
			//  Update 'originItem.quickXorHash' with the correct quickXorHash from the response
			// Everything else should remain the same .. and then save this DB record to the DB ..
			// However, we did this, for the local modified file right before calling this function to update the online timestamp ... so .. do we need to do this again, effectively performing a double DB write for the same data?
			if ((originItem.type != ItemType.remote) && (originItem.remoteType != ItemType.file)) {
				// Save the response JSON
				// Is the response a valid JSON object - validation checking done in saveItem
				saveItem(response);
			} 
		} catch (OneDriveException exception) {
			// Handle a 409 - ETag does not match current item's value
			// Handle a 412 - A precondition provided in the request (such as an if-match header) does not match the resource's current state.
			if ((exception.httpStatusCode == 409) || (exception.httpStatusCode == 412)) {
				// Handle the 409
				if (exception.httpStatusCode == 409) {
					// OneDrive threw a 412 error
					if (verboseLogging) {addLogEntry("OneDrive returned a 'HTTP 409 - ETag does not match current item's value' when attempting file time stamp update - gracefully handling error", ["verbose"]);}
					if (debugLogging) {
						addLogEntry("File Metadata Update Failed - OneDrive eTag / cTag match issue", ["debug"]);
						addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
					}
				}
				// Handle the 412
				if (exception.httpStatusCode == 412) {
					// OneDrive threw a 412 error
					if (verboseLogging) {addLogEntry("OneDrive returned a 'HTTP 412 - Precondition Failed' when attempting file time stamp update - gracefully handling error", ["verbose"]);}
					if (debugLogging) {
						addLogEntry("File Metadata Update Failed - OneDrive eTag / cTag match issue", ["debug"]);
						addLogEntry("Retrying Function: " ~ thisFunctionName, ["debug"]);
					}
				}
				
				// Retry without eTag
				uploadLastModifiedTime(originItem, driveId, id, mtime, null);
			} else {
				// Any other error that should be handled
				// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
				// Display what the error is
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
			}
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			uploadLastModifiedTimeApiInstance.releaseCurlEngine();
			uploadLastModifiedTimeApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Perform a database integrity check - checking all the items that are in-sync at the moment, validating what we know should be on disk, to what is actually on disk
	void performDatabaseConsistencyAndIntegrityCheck() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Log what we are doing
		if (!appConfig.suppressLoggingOutput) {
			addProcessingLogHeaderEntry("Performing a database consistency and integrity check on locally stored data", appConfig.verbosityCount);
		}
		
		// What driveIDsArray do we use? If we are doing a --single-directory we need to use just the drive id associated with that operation
		string[] consistencyCheckDriveIdsArray;
		if (singleDirectoryScope) {
			consistencyCheckDriveIdsArray ~= singleDirectoryScopeDriveId;
		} else {
			// Query the DB for all unique DriveID's
			consistencyCheckDriveIdsArray = itemDB.selectDistinctDriveIds();
		}
		
		// Create a new DB blank item
		Item item;
		// Use the array we populate, rather than selecting all distinct driveId's from the database
		foreach (driveId; consistencyCheckDriveIdsArray) {
			// Make the logging more accurate - we cant update driveId as this then breaks the below queries
			if (verboseLogging) {addLogEntry("Processing DB entries for this Drive ID: " ~ driveId, ["verbose"]);}
			
			// Initialise the array 
			Item[] driveItems = [];
			
			// Freshen the cached quota details for this driveID
			addOrUpdateOneDriveOnlineDetails(driveId);

			// What OneDrive API query do we use?
			// - Are we running against a National Cloud Deployments that does not support /delta ?
			//   National Cloud Deployments do not support /delta as a query
			//   https://docs.microsoft.com/en-us/graph/deployments#supported-features
			//
			// - Are we performing a --single-directory sync, which will exclude many items online, focusing in on a specific online directory
			// - Are we performing a --download-only --cleanup-local-files action?
			// - Are we scanning a Shared Folder
			//
			// If we did, we self generated a /delta response, thus need to now process elements that are still flagged as out-of-sync
			if ((singleDirectoryScope) || (nationalCloudDeployment) || (cleanupLocalFiles) || sharedFolderDeltaGeneration) {
				// Any entry in the DB than is flagged as out-of-sync needs to be cleaned up locally first before we scan the entire DB
				// Normally, this is done at the end of processing all /delta queries, however when using --single-directory or a National Cloud Deployments is configured
				// We cant use /delta to query the OneDrive API as National Cloud Deployments dont support /delta
				// https://docs.microsoft.com/en-us/graph/deployments#supported-features
				// We dont use /delta for --single-directory as, in order to sync a single path with /delta, we need to query the entire OneDrive API JSON data to then filter out
				// objects that we dont want, thus, it is easier to use the same method as National Cloud Deployments, but query just the objects we are after

				// For each unique OneDrive driveID we know about
				Item[] outOfSyncItems = itemDB.selectOutOfSyncItems(driveId);
				foreach (outOfSyncItem; outOfSyncItems) {
					if (!dryRun) {
						// clean up idsToDelete
						idsToDelete.length = 0;
						assumeSafeAppend(idsToDelete);
						// flag to delete local file as it now is no longer in sync with OneDrive
						if (debugLogging) {
							addLogEntry("Flagging to delete local item as it now is no longer in sync with OneDrive", ["debug"]);
							addLogEntry("outOfSyncItem: " ~ to!string(outOfSyncItem), ["debug"]);
						}
						
						// Use the configured values - add the driveId, itemId and parentId values to the array
						idsToDelete ~= [outOfSyncItem.driveId, outOfSyncItem.id, outOfSyncItem.parentId];
						// delete items in idsToDelete
						if (idsToDelete.length > 0) processDeleteItems();
					}
				}
				
				// Clear array
				outOfSyncItems = [];
						
				// Fetch database items associated with this path
				if (singleDirectoryScope) {
					// Use the --single-directory items we previously configured
					// - query database for children objects using those items
					driveItems = getChildren(singleDirectoryScopeDriveId, singleDirectoryScopeItemId);
				} else {
					// Check everything associated with each driveId we know about
					if (debugLogging) {addLogEntry("Selecting DB items via itemDB.selectByDriveId(driveId)", ["debug"]);}
					// Query database
					driveItems = itemDB.selectByDriveId(driveId);
				}
				
				// Log DB items to process
				if (debugLogging) {addLogEntry("Database items to process for this driveId: " ~ to!string(driveItems.count), ["debug"]);}
				
				// Process each database item associated with the driveId
				foreach(dbItem; driveItems) {
					// Does it still exist on disk in the location the DB thinks it is
					checkDatabaseItemForConsistency(dbItem);
				}
			} else {
				// Check everything associated with each driveId we know about
				if (debugLogging) {addLogEntry("Selecting DB items via itemDB.selectByDriveId(driveId)", ["debug"]);}
				
				// Query database
				driveItems = itemDB.selectByDriveId(driveId);
				if (debugLogging) {addLogEntry("Database items to process for this driveId: " ~ to!string(driveItems.count), ["debug"]);}
				
				// Process each database item associated with the driveId
				foreach(dbItem; driveItems) {
					// Does it still exist on disk in the location the DB thinks it is
					checkDatabaseItemForConsistency(dbItem);
				}
			}
			
			// Clear the array
			driveItems = [];
		}

		// Close out the '....' being printed to the console
		if (!appConfig.suppressLoggingOutput) {
			if (appConfig.verbosityCount == 0) {
				completeProcessingDots();
			}
		}
		
		// Are we doing a --download-only sync?
		if (!appConfig.getValueBool("download_only")) {
			
			// Do we have any known items, where they have been deleted locally, that now need to be deleted online?
			if (databaseItemsToDeleteOnline.length > 0) {
				// There are items to delete online
				addLogEntry("Deleted local items to delete on Microsoft OneDrive: " ~ to!string(databaseItemsToDeleteOnline.length));
				foreach(localItemToDeleteOnline; databaseItemsToDeleteOnline) {
					// Upload to OneDrive the instruction to delete this item. This will handle the 'noRemoteDelete' flag if set
					uploadDeletedItem(localItemToDeleteOnline.dbItem, localItemToDeleteOnline.localFilePath);
				}
				// Cleanup array memory
				databaseItemsToDeleteOnline = [];
			}
			
			// Do we have any known items, where the content has changed locally, that needs to be uploaded?
			if (databaseItemsWhereContentHasChanged.length > 0) {
				// There are changed local files that were in the DB to upload
				addLogEntry("Changed local items to upload to Microsoft OneDrive: " ~ to!string(databaseItemsWhereContentHasChanged.length));
				processChangedLocalItemsToUpload();
				// Cleanup array memory
				databaseItemsWhereContentHasChanged = [];
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Check this Database Item for its consistency on disk
	void checkDatabaseItemForConsistency(Item dbItem) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Due to this function, we need to keep the return <bool value>; code, so that this function operates as efficiently as possible.
		// It is pointless having the entire code run through and performing additional needless checks where it is not required
		// Whilst this means some extra code / duplication in this function, it cannot be helped
			
		// What is the local path item
		string localFilePath;
		// Do we want to onward process this item?
		bool unwanted = false;
		
		// Remote directory items we can 'skip'
		if ((dbItem.type == ItemType.remote) && (dbItem.remoteType == ItemType.dir)) {
			
			// Display function processing time if configured to do so
			if (appConfig.getValueBool("display_processing_time") && debugLogging) {
				// Combine module name & running Function
				displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
			}
			
			// return .. nothing to check here, no logging needed
			return;
		}
		
		// Compute this dbItem path early as we we use this path often
		localFilePath = buildNormalizedPath(computeItemPath(dbItem.driveId, dbItem.id));
		
		// To improve logging output for this function, what is the 'logical path'?
		string logOutputPath;
		if (localFilePath == ".") {
			// get the configured sync_dir
			logOutputPath = buildNormalizedPath(appConfig.getValueString("sync_dir"));
		} else {
			// Use the path that was computed
			logOutputPath = localFilePath;
		}
		
		// Log what we are doing
		if (verboseLogging) {addLogEntry("Processing: " ~ logOutputPath, ["verbose"]);}
		// Add a processing '.'
		if (!appConfig.suppressLoggingOutput) {
			if (appConfig.verbosityCount == 0) {
				addProcessingDotEntry();
			}
		}
		
		// Determine which action to take
		final switch (dbItem.type) {
		case ItemType.file:
			// Logging output result is handled by checkFileDatabaseItemForConsistency
			checkFileDatabaseItemForConsistency(dbItem, localFilePath);
			goto functionCompletion;
			
		case ItemType.dir, ItemType.root:
			// Logging output result is handled by checkDirectoryDatabaseItemForConsistency
			checkDirectoryDatabaseItemForConsistency(dbItem, localFilePath);
			goto functionCompletion;
			
		case ItemType.remote:
			// DB items that match: dbItem.remoteType == ItemType.dir - these should have been skipped above
			// This means that anything that hits here should be: dbItem.remoteType == ItemType.file
			checkFileDatabaseItemForConsistency(dbItem, localFilePath);
			goto functionCompletion;
			
		case ItemType.unknown:
		case ItemType.none:
			// Unknown type - we dont action these items
			goto functionCompletion;
		}
		
		// To correctly handle a switch|case statement we use goto post the switch|case statement as if 'break' is used, we never get to this point
		functionCompletion:
			// Display function processing time if configured to do so
			if (appConfig.getValueBool("display_processing_time") && debugLogging) {
				// Combine module name & running Function
				displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
			}
	}
	
	// Perform the database consistency check on this file item
	void checkFileDatabaseItemForConsistency(Item dbItem, string localFilePath) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// What is the source of this item data?
		string itemSource = "database";

		// Does this item|file still exist on disk?
		if (exists(localFilePath)) {
			// Path exists locally, is this path a file?
			if (isFile(localFilePath)) {
				// Can we actually read the local file?
				if (readLocalFile(localFilePath)){
					// File is readable
					SysTime localModifiedTime = timeLastModified(localFilePath).toUTC();
					SysTime itemModifiedTime = dbItem.mtime;
					// Reduce time resolution to seconds before comparing
					itemModifiedTime.fracSecs = Duration.zero;
					localModifiedTime.fracSecs = Duration.zero;
					
					if (localModifiedTime != itemModifiedTime) {
						// The modified dates are different
						if (verboseLogging) {
							addLogEntry("Local file time discrepancy detected: " ~ localFilePath, ["verbose"]);
							addLogEntry("This local file has a different modified time " ~ to!string(localModifiedTime) ~ " (UTC) when compared to " ~ itemSource ~ " modified time " ~ to!string(itemModifiedTime) ~ " (UTC)", ["verbose"]);
						}
						
						// Test the file hash
						if (!testFileHash(localFilePath, dbItem)) {
							// Is the local file 'newer' or 'older' (ie was an old file 'restored locally' by a different backup / replacement process?)
							if (localModifiedTime >= itemModifiedTime) {
								// Local file is newer
								if (!appConfig.getValueBool("download_only")) {
									if (verboseLogging) {addLogEntry("The file content has changed locally and has a newer timestamp, thus needs to be uploaded to OneDrive", ["verbose"]);}
									// Add to an array of files we need to upload as this file has changed locally in-between doing the /delta check and performing this check
									databaseItemsWhereContentHasChanged ~= [dbItem.driveId, dbItem.id, localFilePath];
								} else {
									if (verboseLogging) {addLogEntry("The file content has changed locally and has a newer timestamp. The file will remain different to online file due to --download-only being used", ["verbose"]);}
								}
							} else {
								// Local file is older - data recovery process? something else?
								if (!appConfig.getValueBool("download_only")) {
									if (verboseLogging) {addLogEntry("The file content has changed locally and file now has a older timestamp. Uploading this file to OneDrive may potentially cause data-loss online", ["verbose"]);}
									// Add to an array of files we need to upload as this file has changed locally in-between doing the /delta check and performing this check
									databaseItemsWhereContentHasChanged ~= [dbItem.driveId, dbItem.id, localFilePath];
								} else {
									if (verboseLogging) {addLogEntry("The file content has changed locally and file now has a older timestamp. The file will remain different to online file due to --download-only being used", ["verbose"]);}
								}
							}
						} else {
							// The file contents have not changed, but the modified timestamp has
							if (verboseLogging) {addLogEntry("The last modified timestamp has changed however the file content has not changed", ["verbose"]);}
							
							// Local file is newer .. are we in a --download-only situation?
							if (!appConfig.getValueBool("download_only")) {
								// Not a --download-only scenario
								if (!dryRun) {
									// Attempt to update the online date time stamp
									// We need to use the correct driveId and itemId, especially if we are updating a OneDrive Business Shared File timestamp
									if (dbItem.type == ItemType.file) {
										// Not a remote file
										// Log what is being done
										if (verboseLogging) {addLogEntry("The local item has the same hash value as the item online - correcting timestamp online", ["verbose"]);}
										// Correct timestamp
										uploadLastModifiedTime(dbItem, dbItem.driveId, dbItem.id, localModifiedTime.toUTC(), dbItem.eTag);
									} else {
										// Remote file, remote values need to be used, we may not even have permission to change timestamp, update local file
										if (verboseLogging) {addLogEntry("The local item has the same hash value as the item online, however file is a OneDrive Business Shared File - correcting local timestamp", ["verbose"]);}
										
										// Set the timestamp, logging and error handling done within function
										setLocalPathTimestamp(dryRun, localFilePath, dbItem.mtime);
									}
								}
							} else {
								// --download-only being used
								if (verboseLogging) {addLogEntry("The local item has the same hash value as the item online - correcting local timestamp due to --download-only being used to ensure local file matches timestamp online", ["verbose"]);}
								// Set the timestamp, logging and error handling done within function
								setLocalPathTimestamp(dryRun, localFilePath, dbItem.mtime);
							}
						}
					} else {
						// The file has not changed
						if (verboseLogging) {addLogEntry("The file has not changed", ["verbose"]);}
					}
				} else {
					//The file is not readable - skipped
					addLogEntry("Skipping processing this file as it cannot be read (file permissions or file corruption): " ~ localFilePath);
				}
			} else {
				// The item was a file but now is a directory
				if (verboseLogging) {addLogEntry("The item was a file but now is a directory", ["verbose"]);}
			}
		} else {
			// File does not exist locally, but is in our database as a dbItem containing all the data was passed into this function
			// If we are in a --dry-run situation - this file may never have existed as we never downloaded it
			if (!dryRun) {
				// Not --dry-run situation
				if (verboseLogging) {addLogEntry("The file has been deleted locally", ["verbose"]);}
				// Add this to the array to handle post checking all database items
				databaseItemsToDeleteOnline ~= [DatabaseItemsToDeleteOnline(dbItem, localFilePath)];
			} else {
				// We are in a --dry-run situation, file appears to have been deleted locally - this file may never have existed locally as we never downloaded it due to --dry-run
				// Did we 'fake create it' as part of --dry-run ?
				bool idsFakedMatch = false;
				foreach (i; idsFaked) {
					if (i[1] == dbItem.id) {
						if (debugLogging) {addLogEntry("Matched faked file which is 'supposed' to exist but not created due to --dry-run use", ["debug"]);}
						if (verboseLogging) {addLogEntry("The file has not changed", ["verbose"]);}
						idsFakedMatch = true;
					}
				}
				if (!idsFakedMatch) {
					// dbItem.id did not match a 'faked' download new file creation - so this in-sync object was actually deleted locally, but we are in a --dry-run situation
					if (verboseLogging) {addLogEntry("The file has been deleted locally", ["verbose"]);}
					// Add this to the array to handle post checking all database items
					databaseItemsToDeleteOnline ~= [DatabaseItemsToDeleteOnline(dbItem, localFilePath)];
				}
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Perform the database consistency check on this directory item
	void checkDirectoryDatabaseItemForConsistency(Item dbItem, string localFilePath) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
			
		// What is the source of this item data?
		string itemSource = "database";
		
		// Does this item|directory still exist on disk?
		if (exists(localFilePath)) {
			// Fix https://github.com/abraunegg/onedrive/issues/1915
			try {
				if (!isDir(localFilePath)) {
					if (verboseLogging) {addLogEntry("The item was a directory but now it is a file", ["verbose"]);}
					uploadDeletedItem(dbItem, localFilePath);
					uploadNewFile(localFilePath);
				} else {
					// Directory still exists locally
					if (verboseLogging) {addLogEntry("The directory has not changed", ["verbose"]);}
					// When we are using --single-directory, we use the getChildren() call to get all children of a path, meaning all children are already traversed
					// Thus, if we traverse the path of this directory .. we end up with double processing & log output .. which is not ideal
					if (!singleDirectoryScope) {
						// loop through the children
						Item[] childrenFromDatabase = itemDB.selectChildren(dbItem.driveId, dbItem.id);
						foreach (Item child; childrenFromDatabase) {
							checkDatabaseItemForConsistency(child);
						}
						// Clear DB response array
						childrenFromDatabase = [];
					}
				}
			} catch (FileException e) {
				// display the error message
				displayFileSystemErrorMessage(e.msg, thisFunctionName);
			}
		} else {
			// Directory does not exist locally, but it is in our database as a dbItem containing all the data was passed into this function
			// If we are in a --dry-run situation - this directory may never have existed as we never created it
			if (!dryRun) {
				// Not --dry-run situation
				if (!appConfig.getValueBool("monitor")) {
					// Not in --monitor mode
					if (verboseLogging) {addLogEntry("The directory has been deleted locally", ["verbose"]);}
				} else {
					// Appropriate message as we are in --monitor mode
					if (verboseLogging) {addLogEntry("The directory appears to have been deleted locally .. but we are running in --monitor mode. This may have been 'moved' on the local filesystem rather than being 'deleted'", ["verbose"]);}
					if (debugLogging) {addLogEntry("Most likely cause - 'inotify' event was missing for whatever action was taken locally or action taken when application was stopped", ["debug"]);}
				}
				// A moved directory will be uploaded as 'new', delete the old directory and database reference
				// Add this to the array to handle post checking all database items
				databaseItemsToDeleteOnline ~= [DatabaseItemsToDeleteOnline(dbItem, localFilePath)];
			} else {
				// We are in a --dry-run situation, directory appears to have been deleted locally - this directory may never have existed locally as we never created it due to --dry-run
				// Did we 'fake create it' as part of --dry-run ?
				bool idsFakedMatch = false;
				foreach (i; idsFaked) {
					if (i[1] == dbItem.id) {
						if (debugLogging) {addLogEntry("Matched faked dir which is 'supposed' to exist but not created due to --dry-run use", ["debug"]);}
						if (verboseLogging) {addLogEntry("The directory has not changed", ["verbose"]);}
						idsFakedMatch = true;
					}
				}
				if (!idsFakedMatch) {
					// dbItem.id did not match a 'faked' download new directory creation - so this in-sync object was actually deleted locally, but we are in a --dry-run situation
					if (verboseLogging) {addLogEntry("The directory has been deleted locally", ["verbose"]);}
					// Add this to the array to handle post checking all database items
					databaseItemsToDeleteOnline ~= [DatabaseItemsToDeleteOnline(dbItem, localFilePath)];
				} else {
					// When we are using --single-directory, we use a the getChildren() call to get all children of a path, meaning all children are already traversed
					// Thus, if we traverse the path of this directory .. we end up with double processing & log output .. which is not ideal
					if (!singleDirectoryScope) {
						// loop through the children
						Item[] childrenFromDatabase = itemDB.selectChildren(dbItem.driveId, dbItem.id);
						foreach (Item child; childrenFromDatabase) {
							checkDatabaseItemForConsistency(child);
						}
						// Clear DB response array
						childrenFromDatabase = [];
					}
				}
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Does this local path (directory or file) conform with the Microsoft Naming Restrictions? It needs to conform otherwise we cannot create the directory or upload the file.
	bool checkPathAgainstMicrosoftNamingRestrictions(string localFilePath, string logModifier = "item") {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
			
		// Check if the given path violates certain Microsoft restrictions and limitations
		// Return a true|false response
		bool invalidPath = false;
		
		// Check path against Microsoft OneDrive restriction and limitations about Windows naming for files and folders
		if (!invalidPath) {
			if (!isValidName(localFilePath)) { // This will return false if this is not a valid name according to the OneDrive API specifications
				addLogEntry("Skipping " ~ logModifier ~" - invalid name (Microsoft Naming Convention): " ~ localFilePath, ["info", "notify"]);
				invalidPath = true;
			}
		}
		
		// Check path for bad whitespace items
		if (!invalidPath) {
			if (containsBadWhiteSpace(localFilePath)) { // This will return true if this contains a bad whitespace character
				addLogEntry("Skipping " ~ logModifier ~" - invalid name (Contains an invalid whitespace character): " ~ localFilePath, ["info", "notify"]);
				invalidPath = true;
			}
		}
		
		// Check path for HTML ASCII Codes
		if (!invalidPath) {
			if (containsASCIIHTMLCodes(localFilePath)) { // This will return true if this contains HTML ASCII Codes
				addLogEntry("Skipping " ~ logModifier ~" - invalid name (Contains HTML ASCII Code): " ~ localFilePath, ["info", "notify"]);
				invalidPath = true;
			}
		}
		
		// Validate that the path is a valid UTF-16 encoded path
		if (!invalidPath) {
			if (!isValidUTF16(localFilePath)) { // This will return true if this is a valid UTF-16 encoded path, so we are checking for 'false' as response
				addLogEntry("Skipping " ~ logModifier ~" - invalid name (Invalid UTF-16 encoded path): " ~ localFilePath, ["info", "notify"]);
				invalidPath = true;
			}
		}
		
		// Check path for ASCII Control Codes
		if (!invalidPath) {
			if (containsASCIIControlCodes(localFilePath)) { // This will return true if this contains ASCII Control Codes
				addLogEntry("Skipping " ~ logModifier ~" - invalid name (Contains ASCII Control Codes): " ~ localFilePath, ["info", "notify"]);
				invalidPath = true;
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// Return if this is a valid path
		return invalidPath;
	}
	
	// Does this local path (directory or file) get excluded from any operation based on any client side filtering rules?
	bool checkPathAgainstClientSideFiltering(string localFilePath) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Check the path against client side filtering rules
		// - check_nosync
		// - skip_dotfiles
		// - skip_symlinks
		// - skip_file
		// - skip_dir
		// - sync_list
		// - skip_size
		// Return a true|false response
		bool clientSideRuleExcludesPath = false;
		
		// Reset global syncListDirExcluded
		syncListDirExcluded = false;
		
		// does the path exist?
		if (!exists(localFilePath)) {
			// path does not exist - we cant review any client side rules on something that does not exist locally
			return clientSideRuleExcludesPath;
		}
	
		// - check_nosync
		if (!clientSideRuleExcludesPath) {
			// Do we need to check for .nosync? Only if --check-for-nosync was passed in
			if (appConfig.getValueBool("check_nosync")) {
				if (exists(localFilePath ~ "/.nosync")) {
					if (verboseLogging) {addLogEntry("Skipping item - .nosync found & --check-for-nosync enabled: " ~ localFilePath, ["verbose"]);}
					clientSideRuleExcludesPath = true;
				}
			}
		}
		
		// - skip_dotfiles
		if (!clientSideRuleExcludesPath) {
			// Do we need to check skip dot files if configured
			if (appConfig.getValueBool("skip_dotfiles")) {
				if (isDotFile(localFilePath)) {
					if (verboseLogging) {addLogEntry("Skipping item - .file or .folder: " ~ localFilePath, ["verbose"]);}
					clientSideRuleExcludesPath = true;
				}
			}
		}
		
		// - skip_symlinks
		if (!clientSideRuleExcludesPath) {
			// Is the path a symbolic link
			if (isSymlink(localFilePath)) {
				// if config says so we skip all symlinked items
				if (appConfig.getValueBool("skip_symlinks")) {
					if (verboseLogging) {addLogEntry("Skipping item - skip symbolic links configured: " ~ localFilePath, ["verbose"]);}
					clientSideRuleExcludesPath = true;
				}
				// skip unexisting symbolic links
				else if (!exists(readLink(localFilePath))) {
					// reading the symbolic link failed - is the link a relative symbolic link
					//   drwxrwxr-x. 2 alex alex 46 May 30 09:16 .
					//   drwxrwxr-x. 3 alex alex 35 May 30 09:14 ..
					//   lrwxrwxrwx. 1 alex alex 61 May 30 09:16 absolute.txt -> /home/alex/OneDrivePersonal/link_tests/intercambio/prueba.txt
					//   lrwxrwxrwx. 1 alex alex 13 May 30 09:16 relative.txt -> ../prueba.txt
					//
					// absolute links will be able to be read, but 'relative' links will fail, because they cannot be read based on the current working directory 'sync_dir'
					string currentSyncDir = getcwd();
					string fullLinkPath = buildNormalizedPath(absolutePath(localFilePath));
					string fileName = baseName(fullLinkPath);
					string parentLinkPath = dirName(fullLinkPath);
					// test if this is a 'relative' symbolic link
					chdir(parentLinkPath);
					auto relativeLink = readLink(fileName);
					auto relativeLinkTest = exists(readLink(fileName));
					// reset back to our 'sync_dir'
					chdir(currentSyncDir);
					// results
					if (relativeLinkTest) {
						if (debugLogging) {addLogEntry("Not skipping item - symbolic link is a 'relative link' to target ('" ~ relativeLink ~ "') which can be supported: " ~ localFilePath, ["debug"]);}
					} else {
						addLogEntry("Skipping item - invalid symbolic link: "~ localFilePath, ["info", "notify"]);
						clientSideRuleExcludesPath = true;
					}
				}
			}
		}
		
		// Is this item excluded by user configuration of skip_dir or skip_file?
		if (!clientSideRuleExcludesPath) {
			if (localFilePath != ".") {
				// skip_dir handling
				if (isDir(localFilePath)) {
					if (debugLogging) {addLogEntry("Checking local path: " ~ localFilePath, ["debug"]);}
					
					// Only check path if config is != ""
					if (appConfig.getValueString("skip_dir") != "") {
						// The path that needs to be checked needs to include the '/'
						// This due to if the user has specified in skip_dir an exclusive path: '/path' - that is what must be matched
						if (selectiveSync.isDirNameExcluded(localFilePath.strip('.'))) {
							if (verboseLogging) {addLogEntry("Skipping path - excluded by skip_dir config: " ~ localFilePath, ["verbose"]);}
							clientSideRuleExcludesPath = true;
						}
					}
				}
				
				// skip_file handling
				if (isFile(localFilePath)) {
					if (debugLogging) {addLogEntry("Checking file: " ~ localFilePath, ["debug"]);}
					
					// The path that needs to be checked needs to include the '/'
					// This due to if the user has specified in skip_file an exclusive path: '/path/file' - that is what must be matched
					if (selectiveSync.isFileNameExcluded(localFilePath.strip('.'))) {
						if (verboseLogging) {addLogEntry("Skipping file - excluded by skip_file config: " ~ localFilePath, ["verbose"]);}
						clientSideRuleExcludesPath = true;
					}
				}
			}
		}
	
		// Is this item excluded by user configuration of sync_list?
		if (!clientSideRuleExcludesPath) {
			if (localFilePath != ".") {
				if (syncListConfigured) {
					// sync_list configured and in use
					if (selectiveSync.isPathExcludedViaSyncList(localFilePath)) {
						if ((isFile(localFilePath)) && (appConfig.getValueBool("sync_root_files")) && (rootName(localFilePath.strip('.').strip('/')) == "")) {
							if (debugLogging) {addLogEntry("Not skipping path due to sync_root_files inclusion: " ~ localFilePath, ["debug"]);}
						} else {
							if (exists(appConfig.syncListFilePath)){
								// skipped most likely due to inclusion in sync_list
								
								// is this path a file or directory?
								if (isFile(localFilePath)) {
									// file	
									if (verboseLogging) {addLogEntry("Skipping file - excluded by sync_list config: " ~ localFilePath, ["verbose"]);}
								} else {
									// directory
									if (verboseLogging) {addLogEntry("Skipping path - excluded by sync_list config: " ~ localFilePath, ["verbose"]);}
									// update syncListDirExcluded
									syncListDirExcluded = true;
								}
								
								// flag as excluded
								clientSideRuleExcludesPath = true;
							} else {
								// skipped for some other reason
								if (verboseLogging) {addLogEntry("Skipping path - excluded by user config: " ~ localFilePath, ["verbose"]);}
								clientSideRuleExcludesPath = true;
							}
						}
					}
				}
			}
		}
		
		// Check if this is excluded by a user set maximum filesize to upload
		if (!clientSideRuleExcludesPath) {
			if (isFile(localFilePath)) {
				if (fileSizeLimit != 0) {
					// Get the file size
					long thisFileSize = getSize(localFilePath);
					if (thisFileSize >= fileSizeLimit) {
						if (verboseLogging) {addLogEntry("Skipping file - excluded by skip_size config: " ~ localFilePath ~ " (" ~ to!string(thisFileSize/2^^20) ~ " MB)", ["verbose"]);}
					}
				}
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// return if path is excluded
		return clientSideRuleExcludesPath;
	}
	
	// Does this JSON item (as received from OneDrive API) get excluded from any operation based on any client side filtering rules?
	// This function is used when we are fetching objects from the OneDrive API using a /children query to help speed up what object we query or when checking OneDrive Business Shared Files
	bool checkJSONAgainstClientSideFiltering(JSONValue onedriveJSONItem) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Debug what JSON we are evaluating against Client Side Filtering Rules
		if (debugLogging) {addLogEntry("Checking this JSON against Client Side Filtering Rules: " ~ sanitiseJSONItem(onedriveJSONItem), ["debug"]);}
				
		// Function flag
		bool clientSideRuleExcludesPath = false;
		
		// Check the path against client side filtering rules
		// - check_nosync (MISSING)
		// - skip_dotfiles (MISSING)
		// - skip_symlinks (MISSING)
		// - skip_dir 
		// - skip_file
		// - sync_list
		// - skip_size
		// Return a true|false response
		
		// Use the JSON elements rather than computing a DB struct via makeItem()
		string thisItemId = onedriveJSONItem["id"].str;
		string thisItemDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
		string thisItemParentId = onedriveJSONItem["parentReference"]["id"].str;
		string thisItemName = onedriveJSONItem["name"].str;
		
		// Issue #3336 - Convert thisItemDriveId to lowercase before any test
		if (appConfig.accountType == "personal") {
			thisItemDriveId = transformToLowerCase(thisItemDriveId);
		}
		
		// Is this parent is in the database
		bool parentInDatabase = false;
		
		// Calculate if the Parent Item is in the database so that it can be re-used
		parentInDatabase = itemDB.idInLocalDatabase(thisItemDriveId, thisItemParentId);
		
		// Check if this is excluded by config option: skip_dir 
		if (!clientSideRuleExcludesPath) {
			// Is the item a folder?
			if (isItemFolder(onedriveJSONItem)) {
				// Only check path if config is != ""
				if (!appConfig.getValueString("skip_dir").empty) {
					// work out the 'snippet' path where this folder would be created
					string simplePathToCheck = "";
					string complexPathToCheck = "";
					string matchDisplay = "";
					
					if (hasParentReference(onedriveJSONItem)) {
						// we need to workout the FULL path for this item
						// simple path
						if (("name" in onedriveJSONItem["parentReference"]) != null) {
							simplePathToCheck = onedriveJSONItem["parentReference"]["name"].str ~ "/" ~ onedriveJSONItem["name"].str;
						} else {
							simplePathToCheck = onedriveJSONItem["name"].str;
						}
						if (debugLogging) {addLogEntry("skip_dir path to check (simple):  " ~ simplePathToCheck, ["debug"]);}
						
						// complex path calculation
						if (parentInDatabase) {
							// build up complexPathToCheck based on database data
							complexPathToCheck = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ thisItemName;
							if (debugLogging) {addLogEntry("skip_dir path to check (computed): " ~ complexPathToCheck, ["debug"]);}
						} else {
							if (debugLogging) {addLogEntry("Parent details not in database - unable to compute complex path to check using database data", ["debug"]);}
							// use onedriveJSONItem["parentReference"]["path"].str
							string selfBuiltPath = onedriveJSONItem["parentReference"]["path"].str ~ "/" ~ onedriveJSONItem["name"].str;
							
							// Check for ':' and split if present
							auto splitIndex = selfBuiltPath.indexOf(":");
							if (splitIndex != -1) {
								// Keep only the part after ':'
								selfBuiltPath = selfBuiltPath[splitIndex + 1 .. $];
							}
							
							// set complexPathToCheck to selfBuiltPath and be compatible with computeItemPath() output
							complexPathToCheck = "." ~ selfBuiltPath;
						}
						
						// were we able to compute a complexPathToCheck ?
						if (!complexPathToCheck.empty) {
							// complexPathToCheck must at least start with './' to ensure logging output consistency but also for pattern matching consistency
							if (!startsWith(complexPathToCheck, "./")) {
								complexPathToCheck = "./" ~ complexPathToCheck;
							}
							// log the complex path to check
							if (debugLogging) {addLogEntry("skip_dir path to check (complex): " ~ complexPathToCheck, ["debug"]);}
						}
					} else {
						simplePathToCheck = onedriveJSONItem["name"].str;
					}
					
					// If 'simplePathToCheck' or 'complexPathToCheck' is of the following format:  root:/folder
					// then isDirNameExcluded matching will not work
					if (simplePathToCheck.canFind(":")) {
						if (debugLogging) {addLogEntry("Updating simplePathToCheck to remove 'root:'", ["debug"]);}
						simplePathToCheck = processPathToRemoveRootReference(simplePathToCheck);
					}
					if (complexPathToCheck.canFind(":")) {
						if (debugLogging) {addLogEntry("Updating complexPathToCheck to remove 'root:'", ["debug"]);}
						complexPathToCheck = processPathToRemoveRootReference(complexPathToCheck);
					}
					
					// OK .. what checks are we doing?
					if ((!simplePathToCheck.empty) && (complexPathToCheck.empty)) {
						// just a simple check
						if (debugLogging) {addLogEntry("Performing a simple check only", ["debug"]);}
						clientSideRuleExcludesPath = selectiveSync.isDirNameExcluded(simplePathToCheck);
					} else {
						// simple and complex
						if (debugLogging) {addLogEntry("Performing a simple then complex path match if required", ["debug"]);}
												
						// simple first
						if (debugLogging) {addLogEntry("Performing a simple check first", ["debug"]);}
						clientSideRuleExcludesPath = selectiveSync.isDirNameExcluded(simplePathToCheck);
						if (!clientSideRuleExcludesPath) {
							if (debugLogging) {addLogEntry("Simple match was false, attempting complex match", ["debug"]);}
							// simple didnt match, perform a complex check
							clientSideRuleExcludesPath = selectiveSync.isDirNameExcluded(complexPathToCheck);	
						}
					}
					
					// End Result
					if (debugLogging) {addLogEntry("skip_dir exclude result (directory based): " ~ to!string(clientSideRuleExcludesPath), ["debug"]);}
					if (clientSideRuleExcludesPath) {
						// what path should be displayed if we are excluding
						if (!complexPathToCheck.empty) {
							// try and always use the complex path as it is more complete for application output
							matchDisplay = complexPathToCheck;
						} else {
							matchDisplay = simplePathToCheck;
						}
					
						// This path should be skipped
						if (verboseLogging) {addLogEntry("Skipping path - excluded by skip_dir config: " ~ matchDisplay, ["verbose"]);}
					}
				}
			}
			
			// Is the item a file?
			// We need to check to see if this files path is excluded as well
			if (isItemFile(onedriveJSONItem)) {
			
				// Only check path if config is != ""
				if (!appConfig.getValueString("skip_dir").empty) {
					// variable to check the file path against skip_dir
					string pathToCheck;
					
					if (hasParentReference(onedriveJSONItem)) {
						// use onedriveJSONItem["parentReference"]["path"].str
						string selfBuiltPath = onedriveJSONItem["parentReference"]["path"].str;
						
						// Check for ':' and split if present
						auto splitIndex = selfBuiltPath.indexOf(":");
						if (splitIndex != -1) {
							// Keep only the part after ':'
							selfBuiltPath = selfBuiltPath[splitIndex + 1 .. $];
						}
					
						// update file path to check against 'skip_dir'
						pathToCheck = selfBuiltPath;
						string logItemPath = "." ~ pathToCheck ~ "/" ~ onedriveJSONItem["name"].str;
						
						// perform the skip_dir check for file path
						clientSideRuleExcludesPath = selectiveSync.isDirNameExcluded(pathToCheck);
						
						// result
						if (debugLogging) {addLogEntry("skip_dir exclude result (file based): " ~ to!string(clientSideRuleExcludesPath), ["debug"]);}
						if (clientSideRuleExcludesPath) {
							// this files path should be skipped
							if (verboseLogging) {addLogEntry("Skipping file - file path is excluded by skip_dir config: " ~ logItemPath, ["verbose"]);}
						}
					}
				}
			}
		}
		
		// Check if this is excluded by config option: skip_file
		if (!clientSideRuleExcludesPath) {
			// is the item a file ?
			if (isFileItem(onedriveJSONItem)) {
				// JSON item is a file
				
				// skip_file can contain 4 types of entries:
				// - wildcard - *.txt
				// - text + wildcard - name*.txt
				// - full path + combination of any above two - /path/name*.txt
				// - full path to file - /path/to/file.txt
				
				string exclusionTestPath = "";
				
				// is the parent id in the database?
				if (parentInDatabase) {
					// parent id is in the database, so we can try and calculate the full file path
					string jsonItemPath = "";
					
					// Compute this item path & need the full path for this file
					jsonItemPath = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ thisItemName;
					// Log the calculation
					if (debugLogging) {addLogEntry("New Item calculated full path is: " ~ jsonItemPath, ["debug"]);}
					
					// The path that needs to be checked needs to include the '/'
					// This due to if the user has specified in skip_file an exclusive path: '/path/file' - that is what must be matched
					// However, as 'path' used throughout, use a temp variable with this modification so that we use the temp variable for exclusion checks
					if (!startsWith(jsonItemPath, "/")){
						// Add '/' to the path
						exclusionTestPath = '/' ~ jsonItemPath;
					}
					
					// what are we checking
					if (debugLogging) {addLogEntry("skip_file item to check (full calculated path): " ~ exclusionTestPath, ["debug"]);}
				} else {
					// parent not in database, we can only check using this JSON item's name
					if (!startsWith(thisItemName, "/")){
						// Add '/' to the path
						exclusionTestPath = '/' ~ thisItemName;
					}
					
					// what are we checking
					if (debugLogging) {addLogEntry("skip_file item to check (file name only - parent path not in database): " ~ exclusionTestPath, ["debug"]);}
				}
				
				// Perform the 'skip_file' evaluation
				clientSideRuleExcludesPath = selectiveSync.isFileNameExcluded(exclusionTestPath);
				if (debugLogging) {addLogEntry("Result: " ~ to!string(clientSideRuleExcludesPath), ["debug"]);}
				
				if (clientSideRuleExcludesPath) {
					// This path should be skipped
					if (verboseLogging) {addLogEntry("Skipping file - excluded by skip_file config: " ~ exclusionTestPath, ["verbose"]);}
				}
			}
		}
			
		// Check if this is included or excluded by use of sync_list
		if (!clientSideRuleExcludesPath) {
			// No need to try and process something against a sync_list if it has been configured
			if (syncListConfigured) {
				// Compute the item path if empty - as to check sync_list we need an actual path to check
				
				// What is the path of the new item
				string newItemPath;
				
				// Is the parent in the database? If not, we cannot compute the full path based on the database entries
				// In a --resync scenario - the database is empty
				if (parentInDatabase) {
					// Calculate this items path based on database entries
					if (debugLogging) {addLogEntry("Parent path details are in DB", ["debug"]);}
					newItemPath = computeItemPath(thisItemDriveId, thisItemParentId) ~ "/" ~ thisItemName;
				} else {
					// Parent is not in the database .. we need to compute it .. why ????
					if (appConfig.getValueBool("resync")) {
						if (debugLogging) {addLogEntry("Parent NOT in DB .. we need to manually compute this path due to --resync being used", ["debug"]);}
					} else {
						if (debugLogging) {addLogEntry("Parent NOT in DB .. we need to manually compute this path .......", ["debug"]);}
					}
					
					// gather the applicable path details
					if (("path" in onedriveJSONItem["parentReference"]) != null) {
						// If there is a parent reference path, try and use it
						string selfBuiltPath = onedriveJSONItem["parentReference"]["path"].str ~ "/" ~ onedriveJSONItem["name"].str;
						
						// Check for ':' and split if present
						string[] splitPaths;
						auto splitIndex = selfBuiltPath.indexOf(":");
						if (splitIndex != -1) {
							// Keep only the part after ':'
							splitPaths = selfBuiltPath.split(":");
							selfBuiltPath = splitPaths[1];
						}
						
						// Debug output what the self-built path currently is
						if (debugLogging) {addLogEntry(" - selfBuiltPath currently calculated as: " ~ selfBuiltPath, ["debug"]);}
						
						// Issue #2731
						// Get the remoteDriveId from JSON record
						string remoteDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
						
						// Issue #3336 - Convert driveId to lowercase before any test
						if (appConfig.accountType == "personal") {
							remoteDriveId = transformToLowerCase(remoteDriveId);
						}
						
						// Is this potentially a shared folder? This is the only reliable way to determine this ...
						if (remoteDriveId != appConfig.defaultDriveId) {
							// Yes this JSON is from a Shared Folder
							// Query the database for the 'remote' folder details from the database
							if (debugLogging) {addLogEntry("Query database for this 'remoteDriveId' record: " ~ to!string(remoteDriveId), ["debug"]);}
							
							Item remoteItem;
							itemDB.selectByRemoteDriveId(remoteDriveId, remoteItem);
							if (debugLogging) {addLogEntry("Query returned result (itemDB.selectByRemoteDriveId): " ~ to!string(remoteItem), ["debug"]);}
							
							// Shared Folders present a unique challenge to determine what path needs to be used, especially in a --resync scenario where there are near zero records available to use computeItemPath() 
							// Update the path that will be used to check 'sync_list' with the 'name' of the remoteDriveId database record
							// Issue #3331
							// Avoid duplicating the shared folder root name if already present
							if (!selfBuiltPath.startsWith("/" ~ remoteItem.name ~ "/")) {
								selfBuiltPath = remoteItem.name ~ selfBuiltPath;
								if (debugLogging) {addLogEntry("selfBuiltPath after 'Shared Folder' DB details update = " ~ to!string(selfBuiltPath), ["debug"]);}
							} else {
								if (debugLogging) {addLogEntry("Shared Folder name already present in path; no update needed to selfBuiltPath", ["debug"]);}	
							}
						}
						
						// Issue #2740
						// If selfBuiltPath is containing any sort of URL encoding, due to special characters (spaces, umlaut, or any other character that is HTML encoded, this specific path now needs to be HTML decoded
						// Does the path contain HTML encoding?
						if (containsURLEncodedItems(selfBuiltPath)) {
							// decode it
							if (debugLogging) {addLogEntry("selfBuiltPath for sync_list check needs decoding: " ~ selfBuiltPath, ["debug"]);}
							
							try {
								// try and decode selfBuiltPath
								newItemPath = decodeComponent(selfBuiltPath);
							} catch (URIException exception) {
								// why?
								if (verboseLogging) {
									addLogEntry("ERROR: Unable to URL Decode path: " ~ exception.msg, ["verbose"]);
									addLogEntry("ERROR: To resolve, rename this item online: " ~ selfBuiltPath, ["verbose"]);
								}
								// have to use as-is due to decode error
								newItemPath = selfBuiltPath;
							}
						} else {
							// use as-is
							newItemPath = selfBuiltPath;
						}
						
						// The final format of newItemPath when self building needs to be the same as newItemPath when computed using computeItemPath .. this is handled later below
						if (debugLogging) {addLogEntry("newItemPath as manually computed by selfBuiltPath process = " ~ to!string(selfBuiltPath), ["debug"]);}
					} else {
						// no parent reference path available in provided JSON
						newItemPath = thisItemName;
					}
				}
				
				// The 'newItemPath' needs to be updated to ensure it is in the right format
				// Regardless of built from DB or computed it needs to be in this format:
				//   ./path/path/ etc
				// This then makes the path output with 'sync_list' consistent, and, more importantly consistent for 'sync_list' evaluations
				newItemPath = ensureStartsWithDotSlash(newItemPath);
								
				// Check for HTML entities (e.g., '%20' for space) in newItemPath
				if (containsURLEncodedItems(newItemPath)) {
					if (verboseLogging) {
						addLogEntry("CAUTION:    The JSON element transmitted by the Microsoft OneDrive API includes HTML URL encoded items, which may complicate pattern matching and potentially lead to synchronisation problems for this item.", ["verbose"]);
						addLogEntry("WORKAROUND: An alternative solution could be to change the name of this item through the online platform: " ~ newItemPath, ["verbose"]);
						addLogEntry("See: https://github.com/OneDrive/onedrive-api-docs/issues/1765 for further details", ["verbose"]);
					}
				}
				
				// What path are we checking against sync_list?
				if (debugLogging) {addLogEntry("Path to check against 'sync_list' entries: " ~ newItemPath, ["debug"]);}
				
				// Unfortunately there is no avoiding this call to check if the path is excluded|included via sync_list
				if (selectiveSync.isPathExcludedViaSyncList(newItemPath)) {
					// selective sync advised to skip, however is this a file and are we configured to upload / download files in the root?
					if ((isItemFile(onedriveJSONItem)) && (appConfig.getValueBool("sync_root_files")) && (rootName(newItemPath) == "") ) {
						// This is a file
						// We are configured to sync all files in the root
						// This is a file in the logical root
						clientSideRuleExcludesPath = false;
					} else {
						// Path is unwanted, flag to exclude
						clientSideRuleExcludesPath = true;
						
						// Has this itemId already been flagged as being skipped?
						if (!syncListSkippedParentIds.canFind(thisItemId)) {
							if (isItemFolder(onedriveJSONItem)) {
								// Detail we are skipping this JSON data from online
								if (verboseLogging) {addLogEntry("Skipping path - excluded by sync_list config: " ~ newItemPath, ["verbose"]);}
								// Add this folder id to the elements we have already detailed we are skipping, so we do no output this again
								syncListSkippedParentIds ~= thisItemId;
							}
						}
						
						// Is this is a 'add shortcut to onedrive' link?
						if (isItemRemote(onedriveJSONItem)) {
							// Detail we are skipping this JSON data from online
							if (verboseLogging) {addLogEntry("Skipping Shared Folder Link - excluded by sync_list config: " ~ newItemPath, ["verbose"]);}
							// Add this folder id to the elements we have already detailed we are skipping, so we do no output this again
							syncListSkippedParentIds ~= thisItemId;
						}
					}
				} else {
					// Is this a file or directory?
					if (isItemFile(onedriveJSONItem)) {
						// File included due to 'sync_list' match
						if (verboseLogging) {addLogEntry("Including file - included by sync_list config: " ~ newItemPath, ["verbose"]);}
						
						// Is the parent item in the database?
						if (!parentInDatabase) {
							// Parental database structure needs to be created
							string newParentalPath = dirName(newItemPath);
							// Log that this parental structure needs to be created
							if (verboseLogging) {addLogEntry("Parental Path structure needs to be created to support included file: " ~ newParentalPath, ["verbose"]);}
							// Recursively, stepping backward from 'thisItemParentId', query online, save entry to DB and create the local path structure
							createLocalPathStructure(onedriveJSONItem, newParentalPath);
							
							// If this is --dry-run
							if (dryRun) {
								// we dont create the directory, but we need to track that we 'faked it'
								idsFaked ~= [onedriveJSONItem["parentReference"]["driveId"].str, onedriveJSONItem["parentReference"]["id"].str];
							}
						}
					} else {
						// Directory included due to 'sync_list' match
						if (verboseLogging) {addLogEntry("Including path - included by sync_list config: " ~ newItemPath, ["verbose"]);}
						
						// So that this path is in the DB, we need to add onedriveJSONItem to the DB so that this record can be used to build paths if required
						if (parentInDatabase) {
							// Save this JSON now
							saveItem(onedriveJSONItem);
						}
					}
				}
			}
		}
		
		// Check if this is excluded by a user set maximum filesize to download
		if (!clientSideRuleExcludesPath) {
			if (isItemFile(onedriveJSONItem)) {
				if (fileSizeLimit != 0) {
					if (onedriveJSONItem["size"].integer >= fileSizeLimit) {
						if (verboseLogging) {addLogEntry("Skipping file - excluded by skip_size config: " ~ thisItemName ~ " (" ~ to!string(onedriveJSONItem["size"].integer/2^^20) ~ " MB)", ["verbose"]);}
						clientSideRuleExcludesPath = true;
					}
				}
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// return if path is excluded
		return clientSideRuleExcludesPath;
	}
	
	// Ensure the path passed in, is in the correct format to use when evaluating 'sync_list' rules
	string ensureStartsWithDotSlash(string inputPath) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// Check if the path starts with './'
		if (inputPath.startsWith("./")) {
			return inputPath; // No modification needed
		}

		// Check if the path starts with '/' or does not start with '.' at all
		if (inputPath.startsWith("/")) {
			return "." ~ inputPath; // Prepend '.' to ensure it starts with './'
		}

		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// If the path starts with any other character or is missing './', add './'
		return "./" ~ inputPath;
	}
	
	// When using 'sync_list' if a file is to be included, ensure that the path that the file resides in, is available locally and in the database, and the path exists locally
	void createLocalPathStructure(JSONValue onedriveJSONItem, string newLocalParentalPath) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// Function variables
		bool parentInDatabase;
		JSONValue onlinePathData;
		OneDriveApi onlinePathOneDriveApiInstance;
		onlinePathOneDriveApiInstance = new OneDriveApi(appConfig);
		onlinePathOneDriveApiInstance.initialise();
		string thisItemDriveId;
		string thisItemParentId;
		
		// Log what we received to analyse
		if (debugLogging) {
			addLogEntry("createLocalPathStructure input onedriveJSONItem: " ~ to!string(onedriveJSONItem), ["debug"]);
			addLogEntry("createLocalPathStructure input newLocalParentalPath: " ~ newLocalParentalPath, ["debug"]);
		}
		
		// Configure these variables based on the JSON input
		thisItemDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
		
		// OneDrive Personal JSON responses are in-consistent with not having 'id' available
		if (hasParentReferenceId(onedriveJSONItem)) {
			// Use the parent reference id
			thisItemParentId = onedriveJSONItem["parentReference"]["id"].str;
		}
		
		// To continue, thisItemDriveId and thisItemParentId must not be empty
		if ((thisItemDriveId != "") && (thisItemParentId != "")) {
			// Calculate if the Parent Item is in the database so that it can be re-used
			parentInDatabase = itemDB.idInLocalDatabase(thisItemDriveId, thisItemParentId);
			
			// Is the parent in the database?
			if (!parentInDatabase) {
				// Get data from online for this driveId and JSON item parent .. so we have the parent details
				if (debugLogging) {addLogEntry("createLocalPathStructure parent is not in database, fetching parental details from online", ["debug"]);}
				try {
					onlinePathData = onlinePathOneDriveApiInstance.getPathDetailsById(thisItemDriveId, thisItemParentId);
				} catch (OneDriveException exception) {
					// Display what the error is
					// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
					displayOneDriveErrorMessage(exception.msg, thisFunctionName);
				}
				
				// There needs to be a valid JSON to process
				if (onlinePathData.type() == JSONType.object) {
					// Does this JSON match the root name of a shared folder we may be trying to match?
					if (sharedFolderDeltaGeneration) {
						if (currentSharedFolderName == onlinePathData["name"].str) {
							if (debugLogging) {addLogEntry("createLocalPathStructure parent matches the current shared folder name, creating applicable shared folder database records", ["debug"]);}
							// Create a 'root' and 'Shared Folder' DB Tie Records for this JSON object in a consistent manner
							createRequiredSharedFolderDatabaseRecords(onlinePathData);
						}
					} 
					
					// Configure the grandparent items
					string grandparentItemDriveId;
					string grandparentItemParentId;
					grandparentItemDriveId = onlinePathData["parentReference"]["driveId"].str;
					
					// OneDrive Personal JSON responses are in-consistent with not having 'id' available
					if (hasParentReferenceId(onlinePathData)) {
						// Use the parent reference id
						grandparentItemParentId = onlinePathData["parentReference"]["id"].str;
					} else {
						// Testing evidence shows that for Personal accounts, use the 'id' itself
						grandparentItemParentId = onlinePathData["id"].str;
					}
					
					// Is this item's grandparent data in the database?
					if (!itemDB.idInLocalDatabase(grandparentItemDriveId, grandparentItemParentId)) {
						// grandparent needs to be added
						createLocalPathStructure(onlinePathData, dirName(newLocalParentalPath));
					}
					
					// If this is --dry-run
					if (dryRun) {
						// we dont create the directory, but we need to track that we 'faked it'
						idsFaked ~= [grandparentItemDriveId, grandparentItemParentId];
					}
					
					// Does the parental path exist locally?
					if (!exists(newLocalParentalPath)) {
						// the required path does not exist locally - logging is done in handleLocalDirectoryCreation
						// create a db item record for the online data
						Item newDatabaseItem = makeItem(onlinePathData);
						// create the path locally, save the data to the database post path creation
						handleLocalDirectoryCreation(newDatabaseItem, newLocalParentalPath, onlinePathData);
					} else {
						// parent path exists locally, save the data to the database
						saveItem(onlinePathData);
					}
				} else {
					// No valid JSON was responded with - unable to create local path structure
					addLogEntry("Unable to create the local path structure as the Microsoft OneDrive API returned an invalid response");
				}
			} else {
				if (debugLogging) {addLogEntry("createLocalPathStructure parent is in the database", ["debug"]);}
			}
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		onlinePathOneDriveApiInstance.releaseCurlEngine();
		onlinePathOneDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Process the list of local changes to upload to OneDrive
	void processChangedLocalItemsToUpload() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Each element in this array 'databaseItemsWhereContentHasChanged' is an Database Item ID that has been modified locally
		size_t batchSize = to!int(appConfig.getValueLong("threads"));
		long batchCount = (databaseItemsWhereContentHasChanged.length + batchSize - 1) / batchSize;
		long batchesProcessed = 0;
		
		// For each batch of files to upload, upload the changed data to OneDrive
		foreach (chunk; databaseItemsWhereContentHasChanged.chunks(batchSize)) {
			processChangedLocalItemsToUploadInParallel(chunk);
		}
		
		// For this set of items, perform a DB PASSIVE checkpoint
		itemDB.performCheckpoint("PASSIVE");
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}

	// Process all the changed local items in parallel
	void processChangedLocalItemsToUploadInParallel(string[3][] array) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}

		// This function received an array of string items to upload, the number of elements based on appConfig.getValueLong("threads")
		foreach (i, localItemDetails; processPool.parallel(array)) {
			if (debugLogging) {addLogEntry("Upload Thread " ~ to!string(i) ~ " Starting: " ~ to!string(Clock.currTime()), ["debug"]);}
			uploadChangedLocalFileToOneDrive(localItemDetails);
			if (debugLogging) {addLogEntry("Upload Thread " ~ to!string(i) ~ " Finished: " ~ to!string(Clock.currTime()), ["debug"]);}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Upload changed local files to OneDrive in parallel
	void uploadChangedLocalFileToOneDrive(string[3] localItemDetails) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// These are the details of the item we need to upload
		string changedItemDriveId = localItemDetails[0];
		string changedItemId = localItemDetails[1];
		string localFilePath = localItemDetails[2];
		
		// Log the path that was modified
		if (debugLogging) {addLogEntry("uploadChangedLocalFileToOneDrive: " ~ localFilePath, ["debug"]);}
		
		// How much space is remaining on OneDrive
		long remainingFreeSpace;
		// Did the upload fail?
		bool uploadFailed = false;
		// Did we skip due to exceeding maximum allowed size?
		bool skippedMaxSize = false;
		// Did we skip to an exception error?
		bool skippedExceptionError = false;
		// Flag for if space is available online
		bool spaceAvailableOnline = false;
		
		// Capture what time this upload started
		SysTime uploadStartTime = Clock.currTime();
		
		// When we are uploading OneDrive Business Shared Files, we need to be targeting the right driveId and itemId
		string targetDriveId;
		string targetItemId;
		
		// Unfortunately, we cant store an array of Item's ... so we have to re-query the DB again - unavoidable extra processing here
		// This is because the Item[] has no other functions to allow is to parallel process those elements, so we have to use a string array as input to this function
		Item dbItem;
		itemDB.selectById(changedItemDriveId, changedItemId, dbItem);
		
		// Was a valid DB response returned
		if (!dbItem.driveId.empty) {
			// Is this a remote driveId target based on the database response?
			if ((dbItem.type == ItemType.remote) && (dbItem.remoteType == ItemType.file)) {
				// This is a remote file
				targetDriveId = dbItem.remoteDriveId;
				targetItemId = dbItem.remoteId;
				// we are going to make the assumption here that as this is a OneDrive Business Shared File, that there is space available
				spaceAvailableOnline = true;
			} else {
				// This is not a remote file
				targetDriveId = dbItem.driveId;
				targetItemId = dbItem.id;
			}
		} else {
			// No valid DB response was provided
			if (debugLogging) {
				string logMessage = format("No valid DB response was provided when searching for '%s' and '%s'", changedItemDriveId, changedItemId);
				addLogEntry(logMessage, ["debug"]);
				
				// Fetch the online data again for this file 
				addLogEntry("Fetching latest online details for this item due to zero DB data available", ["debug"]);
			}
				
			OneDriveApi checkFileOneDriveApiInstance;
			JSONValue fileDetailsFromOneDrive;
			
			// Create a new API Instance for this thread and initialise it
			checkFileOneDriveApiInstance = new OneDriveApi(appConfig);
			checkFileOneDriveApiInstance.initialise();

			// Try and get the absolute latest object details from online to potentially build a DB record we can use
			try {
				fileDetailsFromOneDrive = checkFileOneDriveApiInstance.getPathDetailsById(changedItemDriveId, changedItemId);
			} catch (OneDriveException exception) {
				// Display what the error is
				// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
			}
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			checkFileOneDriveApiInstance.releaseCurlEngine();
			checkFileOneDriveApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			
			// Turn 'fileDetailsFromOneDrive' into a DB item
			if (fileDetailsFromOneDrive.type() == JSONType.object) {
				// Yes
				if (debugLogging) {addLogEntry("Creating DB item from online API response: " ~ to!string(fileDetailsFromOneDrive), ["debug"]);}
				dbItem = makeItem(fileDetailsFromOneDrive);
			} else {
				// No
				addLogEntry("Unable to upload this modified file at this point in time: " ~ localFilePath);
				return;
			}
		}
		
		// Are we in an --upload-only & --remove-source-files scenario?
		// - In this scenario, and even more so in a --resync scenario when using these options, there is potentially 100% zero database entry for the modified file we are uploading
		//   This will be in the logs when we are in this scenario:
		//     Skipping adding to database as --upload-only & --remove-source-files configured
		if ((uploadOnly) && (localDeleteAfterUpload)) {
			// We are in the potential scenario where 'targetDriveId' and 'targetItemId' are still an empty value(s)
			// Check targetDriveId
			if (targetDriveId.empty) {
				if (debugLogging) {
					string logMessage = format("Updating 'targetDriveId' to '%s' due to --upload-only and --remove-source-files being used", changedItemDriveId);
					addLogEntry(logMessage, ["debug"]);
				}
				// set the value
				targetDriveId = changedItemDriveId;
			}
			// Check targetItemId	
			if (targetItemId.empty) {
				if (debugLogging) {
					string logMessage = format("Updating 'targetItemId' to '%s' due to --upload-only and --remove-source-files being used", changedItemId);
					addLogEntry(logMessage, ["debug"]);
				}
				// set the value
				targetItemId = changedItemId;
			}
		}
			
		// Fetch the details from cachedOnlineDriveData if this is available
		// - cachedOnlineDriveData.quotaRestricted;
		// - cachedOnlineDriveData.quotaAvailable;
		// - cachedOnlineDriveData.quotaRemaining;
		DriveDetailsCache cachedOnlineDriveData;
		
		// Query the details using the correct 'targetDriveId' for this modified file to be uploaded
		cachedOnlineDriveData = getDriveDetails(targetDriveId);
		
		// Configure 'remainingFreeSpace' based on the 'targetDriveId'
		remainingFreeSpace = cachedOnlineDriveData.quotaRemaining;
		
		// Get the file size from the actual file
		long thisFileSizeLocal = getSize(localFilePath);
		
		// Get the file size from the DB data, if DB data was returned, otherwise we have zero size value from the DB
		long thisFileSizeFromDB;
		if (!dbItem.size.empty) {
			thisFileSizeFromDB = to!long(dbItem.size);
		} else {
			thisFileSizeFromDB = 0;
		}
		
		// 'remainingFreeSpace' online includes the current file online
		// We need to remove the online file (add back the existing file size) then take away the new local file size to get a new approximate value
		long calculatedSpaceOnlinePostUpload = (remainingFreeSpace + thisFileSizeFromDB) - thisFileSizeLocal;
		
		// Based on what we know, for this thread - can we safely upload this modified local file?
		if (debugLogging) {
			string estimatedMessage = format("This Thread (Upload Changed File) Estimated Free Space Online (%s): ", targetDriveId);
			addLogEntry(estimatedMessage ~ to!string(remainingFreeSpace), ["debug"]);
			addLogEntry("This Thread (Upload Changed File) Calculated Free Space Online Post Upload: " ~ to!string(calculatedSpaceOnlinePostUpload), ["debug"]);
		}
		
		// Is there quota available for the given drive where we are uploading to?
		// 	If 'personal' accounts, if driveId == defaultDriveId, then we will have quota data - cachedOnlineDriveData.quotaRemaining will be updated so it can be reused
		// 	If 'personal' accounts, if driveId != defaultDriveId, then we will not have quota data - cachedOnlineDriveData.quotaRestricted will be set as true
		// 	If 'business' accounts, if driveId == defaultDriveId, then we will potentially have quota data - cachedOnlineDriveData.quotaRemaining will be updated so it can be reused
		// 	If 'business' accounts, if driveId != defaultDriveId, then we will potentially have quota data, but it most likely will be a 0 value - cachedOnlineDriveData.quotaRestricted will be set as true
		if (cachedOnlineDriveData.quotaAvailable) {
			// Our query told us we have free space online .. if we upload this file, will we exceed space online - thus upload will fail during upload?
			if (calculatedSpaceOnlinePostUpload > 0) {
				// Based on this thread action, we believe that there is space available online to upload - proceed
				spaceAvailableOnline = true;
			}
		}
		
		// Is quota being restricted?
		if (cachedOnlineDriveData.quotaRestricted) {
			// Space available online is being restricted - so we have no way to really know if there is space available online
			spaceAvailableOnline = true;
		}
			
		// Do we have space available or is space available being restricted (so we make the blind assumption that there is space available)
		JSONValue uploadResponse;
		if (spaceAvailableOnline) {
			// Does this file exceed the maximum file size to upload to OneDrive?
			if (thisFileSizeLocal <= maxUploadFileSize) {
				// Attempt to upload the modified file
				// Error handling is in performModifiedFileUpload(), and the JSON that is responded with - will either be null or a valid JSON object containing the upload result
				uploadResponse = performModifiedFileUpload(dbItem, localFilePath, thisFileSizeLocal);
				
				// Evaluate the returned JSON uploadResponse
				// If there was an error uploading the file, uploadResponse should be empty and invalid
				if (uploadResponse.type() != JSONType.object) {
					uploadFailed = true;
					skippedExceptionError = true;
				}
				
			} else {
				// Skip file - too large
				uploadFailed = true;
				skippedMaxSize = true;
			}
		} else {
			// Cant upload this file - no space available
			uploadFailed = true;
		}
		
		// Did the upload fail?
		if (uploadFailed) {
			// Upload failed .. why?
			// No space available online
			if (!spaceAvailableOnline) {
				addLogEntry("Skipping uploading modified file: " ~ localFilePath ~ " due to insufficient free space available on Microsoft OneDrive", ["info", "notify"]);
			}
			// File exceeds max allowed size
			if (skippedMaxSize) {
				addLogEntry("Skipping uploading this modified file as it exceeds the maximum size allowed by Microsoft OneDrive: " ~ localFilePath, ["info", "notify"]);
			}
			// Generic message
			if (skippedExceptionError) {
				// normal failure message if API or exception error generated
				// If Issue #2626 | Case 2-1 is triggered, the file we tried to upload was renamed, then uploaded as a new name
				if (exists(localFilePath)) {
					// Issue #2626 | Case 2-1 was not triggered, file still exists on local filesystem
					addLogEntry("Uploading modified file: " ~ localFilePath ~ " ... failed!", ["info", "notify"]);
				}
			}
		} else {
			// Upload was successful
			addLogEntry("Uploading modified file: " ~ localFilePath ~ " ... done", fileTransferNotifications());
			
			// As no upload failure, calculate transfer metrics in a consistent manner
			displayTransferMetrics(localFilePath, thisFileSizeLocal, uploadStartTime, Clock.currTime());
			
			// What do we save to the DB? Is this a OneDrive Business Shared File?
			if ((dbItem.type == ItemType.remote) && (dbItem.remoteType == ItemType.file)) {
				// We need to 'massage' the old DB record, with data from online, as the DB record was specifically crafted for OneDrive Business Shared Files
				Item tempItem = makeItem(uploadResponse);
				dbItem.eTag = tempItem.eTag;
				dbItem.cTag = tempItem.cTag;
				dbItem.mtime = tempItem.mtime;
				dbItem.quickXorHash = tempItem.quickXorHash;
				dbItem.sha256Hash = tempItem.sha256Hash;
				dbItem.size = tempItem.size;
				itemDB.upsert(dbItem);
			} else {
				// Save the response JSON item in database as is
				saveItem(uploadResponse);
			}
			
			// Update the 'cachedOnlineDriveData' record for this 'targetDriveId' so that this is tracked as accurately as possible for other threads
			updateDriveDetailsCache(targetDriveId, cachedOnlineDriveData.quotaRestricted, cachedOnlineDriveData.quotaAvailable, thisFileSizeLocal);
			
			// Check the integrity of the uploaded modified file if not in a --dry-run scenario
			if (!dryRun) {
				bool uploadIntegrityPassed;
				// Check the integrity of the uploaded modified file, if the local file still exists
				uploadIntegrityPassed = performUploadIntegrityValidationChecks(uploadResponse, localFilePath, thisFileSizeLocal);
				
				// Update the date / time of the file online to match the local item
				// Get the local file last modified time
				SysTime localModifiedTime = timeLastModified(localFilePath).toUTC();
				// Drop fractional seconds for upload timestamp modification as Microsoft OneDrive does not support fractional seconds
				localModifiedTime.fracSecs = Duration.zero;
				
				// Get the latest eTag, and use that
				string etagFromUploadResponse = uploadResponse["eTag"].str;
				
				// Attempt to update the online lastModifiedDateTime value based on our local timestamp data
				if (appConfig.accountType == "personal") {
					// Personal Account Handling for Modified File Upload
					//
					// Did the upload integrity check pass or fail?
					if (!uploadIntegrityPassed) {
						// upload integrity check failed for the modified file
						if (!appConfig.getValueBool("create_new_file_version")) {
							// warn that file differences will exist online
							// as this is a 'personal' account .. we have no idea / reason potentially, so do not download the 'online' file
							addLogEntry("WARNING: The file uploaded to Microsoft OneDrive does not match your local version. Data loss may occur.");
						} else {
							// Create a new online version of the file by updating the online metadata
							uploadLastModifiedTime(dbItem, targetDriveId, targetItemId, localModifiedTime, etagFromUploadResponse);
						}
					} else {
						// Upload of the modified file passed integrity checks
						// We need to make sure that the local file on disk has this timestamp from this JSON, otherwise on the next application run:
						//   The last modified timestamp has changed however the file content has not changed
						//   The local item has the same hash value as the item online - correcting timestamp online
						// This then creates another version online which we do not want to do .. unless configured to do so
						if (!appConfig.getValueBool("create_new_file_version")) {
							// Are we in an --upload-only scenario?
							// In in an --upload-only scenario, it is pointless updating the local timestamp with that what is now online
							if(!uploadOnly){
								// Create an applicable DB item from the upload JSON response
								Item onlineItem;
								onlineItem = makeItem(uploadResponse);
								// Correct the local file timestamp to avoid creating a new version online
								// Set the local timestamp, logging and error handling done within function
								setLocalPathTimestamp(dryRun, localFilePath, onlineItem.mtime);
							}	
						} else {
							// Create a new online version of the file by updating the metadata, which negates the need to download the file
							uploadLastModifiedTime(dbItem, targetDriveId, targetItemId, localModifiedTime, etagFromUploadResponse);	
						}
					}
				} else {
					// Business | SharePoint Account Handling for Modified File Upload
					//
					// Due to https://github.com/OneDrive/onedrive-api-docs/issues/935 Microsoft modifies all PDF, MS Office & HTML files with added XML content. It is a 'feature' of SharePoint.
					// This means that the file which was uploaded, is potentially no longer the file we have locally
					// There are 2 ways to solve this:
					//   1. Download the modified file immediately after upload as per v2.4.x (default)
					//   2. Create a new online version of the file, which then contributes to the users 'quota'
					// Did the upload integrity check pass or fail?
					if (!uploadIntegrityPassed) {
						// upload integrity check failed for the modified file
						if (!appConfig.getValueBool("create_new_file_version")) {
							// Are we in an --upload-only scenario?
							if(!uploadOnly){
								// Download the now online modified file
								addLogEntry("WARNING: Microsoft OneDrive modified your uploaded file via its SharePoint 'enrichment' feature. To keep your local and online versions consistent, the altered file will now be downloaded.");
								addLogEntry("WARNING: Please refer to https://github.com/OneDrive/onedrive-api-docs/issues/935 for further details.");
								// Download the file directly using the prior upload JSON response
								downloadFileItem(uploadResponse, true);
							} else {
								// --upload-only being used
								// we are not downloading a file, warn that file differences will exist
								addLogEntry("WARNING: The file uploaded to Microsoft OneDrive has been modified through its SharePoint 'enrichment' process and no longer matches your local version.");
								addLogEntry("WARNING: Please refer to https://github.com/OneDrive/onedrive-api-docs/issues/935 for further details.");
							}
						} else {
							// Create a new online version of the file by updating the metadata, which negates the need to download the file
							uploadLastModifiedTime(dbItem, targetDriveId, targetItemId, localModifiedTime, etagFromUploadResponse);
						}
					} else {
						// Upload of the modified file passed integrity checks
						// We need to make sure that the local file on disk has this timestamp from this JSON, otherwise on the next application run:
						//   The last modified timestamp has changed however the file content has not changed
						//   The local item has the same hash value as the item online - correcting timestamp online
						// This then creates another version online which we do not want to do .. unless configured to do so
						if (!appConfig.getValueBool("create_new_file_version")) {
							// Are we in an --upload-only scenario?
							// In in an --upload-only scenario, it is pointless updating the local timestamp with that what is now online
							if(!uploadOnly){
								// Create an applicable DB item from the upload JSON response
								Item onlineItem;
								onlineItem = makeItem(uploadResponse);
								// Correct the local file timestamp to avoid creating a new version online
								// Set the timestamp, logging and error handling done within function
								setLocalPathTimestamp(dryRun, localFilePath, onlineItem.mtime);
							}
						} else {
							// Create a new online version of the file by updating the metadata, which negates the need to download the file
							uploadLastModifiedTime(dbItem, targetDriveId, targetItemId, localModifiedTime, etagFromUploadResponse);	
						}
					}
				}
				
				// Are we in an --upload-only & --remove-source-files scenario?
				if ((uploadOnly) && (localDeleteAfterUpload)) {
					// Perform the local file deletion
					removeLocalFilePostUpload(localFilePath);
				}
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Remove the local file if using --upload-only & --remove-source-files scenario in a consistent manner
	void removeLocalFilePostUpload(string localPathToRemove) {
		// File has to exist before removal
		if (exists(localPathToRemove)) {
			// Log that we are deleting a local item
			addLogEntry("Attempting removal of local file as --upload-only & --remove-source-files configured");
			
			// Are we in a --dry-run scenario?
			if (!dryRun) {
				// Not in a --dry-run scenario
				if (debugLogging) {addLogEntry("Removing local file: " ~ localPathToRemove, ["debug"]);}
				safeRemove(localPathToRemove);
				addLogEntry("Removed local file:  " ~ localPathToRemove);
			} else {
				// --dry-run scenario
				addLogEntry("Not removing local file as --dry-run configured");
			}
		} else {
			// Log that the path to remove does not exist locally
			addLogEntry("Removing local file not possible as local file does not exist");
		}
	}
		
	// Perform the upload of a locally modified file to OneDrive
	JSONValue performModifiedFileUpload(Item dbItem, string localFilePath, long thisFileSizeLocal) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
			
		// Function variables
		JSONValue uploadResponse;
		OneDriveApi uploadFileOneDriveApiInstance;
		uploadFileOneDriveApiInstance = new OneDriveApi(appConfig);
		uploadFileOneDriveApiInstance.initialise();
		
		// Configure JSONValue variables we use for a session upload
		JSONValue currentOnlineJSONData;
		Item currentOnlineItemData;
		JSONValue uploadSessionData;
		string currentETag;
		
		// When we are uploading OneDrive Business Shared Files, we need to be targeting the right driveId and itemId
		string targetDriveId;
		string targetParentId;
		string targetItemId;
		
		// Is this a remote target?
		if ((dbItem.type == ItemType.remote) && (dbItem.remoteType == ItemType.file)) {
			// This is a remote file
			targetDriveId = dbItem.remoteDriveId;
			targetParentId = dbItem.remoteParentId;
			targetItemId = dbItem.remoteId;
		} else {
			// This is not a remote file
			targetDriveId = dbItem.driveId;
			targetParentId = dbItem.parentId;
			targetItemId = dbItem.id;
		}
		
		// Is this a dry-run scenario?
		if (!dryRun) {
			// Do we use simpleUpload or create an upload session?
			bool useSimpleUpload = false;
			
			// Try and get the absolute latest object details from online, so we get the latest eTag to try and avoid a 412 eTag error
			try {
				currentOnlineJSONData = uploadFileOneDriveApiInstance.getPathDetailsById(targetDriveId, targetItemId);
			} catch (OneDriveException exception) {
				// Display what the error is
				// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
			}
			
			// Was a valid JSON response provided?
			if (currentOnlineJSONData.type() == JSONType.object) {
				// Does the response contain an eTag?
				if (hasETag(currentOnlineJSONData)) {
					// Use the value returned from online as this will attempt to avoid a 412 response if we are creating a session upload
					currentETag = currentOnlineJSONData["eTag"].str;
				} else {
					// Use the database value - greater potential for a 412 error to occur if we are creating a session upload
					if (debugLogging) {addLogEntry("Online data for file returned zero eTag - using database eTag value", ["debug"]);}
					currentETag = dbItem.eTag;
				}
				
				// Make a reusable item from this online JSON data
				currentOnlineItemData = makeItem(currentOnlineJSONData);
				
			} else {
				// no valid JSON response - greater potential for a 412 error to occur if we are creating a session upload
				if (debugLogging) {addLogEntry("Online data returned was invalid - using database eTag value", ["debug"]);}
				currentETag = dbItem.eTag;
			}
			
			// What upload method should be used?
			if (thisFileSizeLocal <= sessionThresholdFileSize) {
				// file size is below session threshold
				useSimpleUpload = true;
			}
			
			// Use Session Upload regardless
			if (appConfig.getValueBool("force_session_upload")) {
				// Forcing session upload
				if (debugLogging) {addLogEntry("Forcing to perform upload using a session (modified)", ["debug"]);}
				useSimpleUpload = false;
			}
			
			// If the filesize is greater than zero , and we have valid 'latest' online data is the online file matching what we think is in the database?
			if ((thisFileSizeLocal > 0) && (currentOnlineJSONData.type() == JSONType.object)) {
				// Issue #2626 | Case 2-1 
				// If the 'online' file is newer, this will be overwritten with the file from the local filesystem - potentially constituting online data loss
				Item onlineFile = makeItem(currentOnlineJSONData);
				
				// Which file is technically newer? The local file or the remote file?
				SysTime localModifiedTime = timeLastModified(localFilePath).toUTC();
				SysTime onlineModifiedTime = onlineFile.mtime;
				
				// Reduce time resolution to seconds before comparing
				localModifiedTime.fracSecs = Duration.zero;
				onlineModifiedTime.fracSecs = Duration.zero;
				
				// Which file is newer? If local is newer, it will be uploaded as a modified file in the correct manner
				if (localModifiedTime < onlineModifiedTime) {
					// Online File is actually newer than the locally modified file
					if (debugLogging) {
						addLogEntry("currentOnlineJSONData: " ~ to!string(currentOnlineJSONData), ["debug"]);
						addLogEntry("onlineFile:    " ~ to!string(onlineFile), ["debug"]);
						addLogEntry("database item: " ~ to!string(dbItem), ["debug"]);
					}
					addLogEntry("Skipping uploading this item as a locally modified file, will upload as a new file (online file already exists and is newer): " ~ localFilePath);
					
					// Online is newer, rename local, then upload the renamed file
					// We need to know the renamed path so we can upload it
					string renamedPath;
					// Rename the local path - we WANT this to occur regardless of bypassDataPreservation setting
					safeBackup(localFilePath, dryRun, false, renamedPath);
					// Upload renamed local file as a new file
					uploadNewFile(renamedPath);
					
					// Process the database entry removal for the original file. In a --dry-run scenario, this is being done against a DB copy.
					// This is done so we can download the newer online file
					itemDB.deleteById(targetDriveId, targetItemId);

					// This file is now uploaded, return from here, but this will trigger a response that the upload failed (technically for the original filename it did, but we renamed it, then uploaded it
					return uploadResponse;
				}
			}
			
			// We can only upload zero size files via simpleFileUpload regardless of account type
			// Reference: https://github.com/OneDrive/onedrive-api-docs/issues/53
			// Additionally, all files where file size is < 4MB should be uploaded by simpleUploadReplace - everything else should use a session to upload the modified file
			if ((thisFileSizeLocal == 0) || (useSimpleUpload)) {
				// Must use Simple Upload to replace the file online
				try {
					uploadResponse = uploadFileOneDriveApiInstance.simpleUploadReplace(localFilePath, targetDriveId, targetItemId);
				} catch (OneDriveException exception) {
					// HTTP request returned status code 403
					if ((exception.httpStatusCode == 403) && (appConfig.getValueBool("sync_business_shared_files"))) {
						// We attempted to upload a file, that was shared with us, but this was shared with us as read-only
						addLogEntry("Unable to upload this modified file as this was shared as read-only: " ~ localFilePath);
					}
					// HTTP request returned status code 423
					// Resolve https://github.com/abraunegg/onedrive/issues/36
					if (exception.httpStatusCode == 423) {
						// The file is currently checked out or locked for editing by another user
						// We cant upload this file at this time
						addLogEntry("Unable to upload this modified file as this is currently checked out or locked for editing by another user: " ~ localFilePath);
					} else {
						// Handle all other HTTP status codes
						// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
						// Display what the error is
						displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					}
				} catch (FileException e) {
					// filesystem error
					displayFileSystemErrorMessage(e.msg, thisFunctionName);
				}
			} else {
				// As this is a unique thread, the sessionFilePath for where we save the data needs to be unique
				// The best way to do this is generate a 10 digit alphanumeric string, and use this as the file extension
				string threadUploadSessionFilePath = appConfig.uploadSessionFilePath ~ "." ~ generateAlphanumericString();
				
				// Create the upload session using the latest online data 'currentOnlineData' etag
				try {
					// create the session
					uploadSessionData = createSessionForFileUpload(uploadFileOneDriveApiInstance, localFilePath, targetDriveId, targetParentId, baseName(localFilePath), currentOnlineItemData.eTag, threadUploadSessionFilePath);
				} catch (OneDriveException exception) {
					// HTTP request returned status code 403
					if ((exception.httpStatusCode == 403) && (appConfig.getValueBool("sync_business_shared_files"))) {
						// We attempted to upload a file, that was shared with us, but this was shared with us as read-only
						addLogEntry("Unable to upload this modified file as this was shared as read-only: " ~ localFilePath);
						return uploadResponse;
					} 
					
					// HTTP request returned status code 423
					// Resolve https://github.com/abraunegg/onedrive/issues/36
					if (exception.httpStatusCode == 423) {
						// The file is currently checked out or locked for editing by another user
						// We cant upload this file at this time
						addLogEntry("Unable to upload this modified file as this is currently checked out or locked for editing by another user: " ~ localFilePath);
						return uploadResponse;
					} else {
						// Handle all other HTTP status codes
						// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
						// Display what the error is
						displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					}
				} catch (FileException e) {
					addLogEntry("DEBUG TO REMOVE: Modified file upload FileException Handling (Create the Upload Session)");
					displayFileSystemErrorMessage(e.msg, thisFunctionName);
				}
				
				// Do we have a valid session URL that we can use ?
				if (uploadSessionData.type() == JSONType.object) {
					// This is a valid JSON object
					// Perform the upload using the session that has been created
					try {
						// so that we have this data available if we need to re-create the session
						// - targetDriveId, targetParentId, baseName(localFilePath), currentOnlineItemData.eTag, threadUploadSessionFilePath
						uploadSessionData["targetDriveId"] = targetDriveId;
						uploadSessionData["targetParentId"] = targetParentId;
						uploadSessionData["currentETag"] = currentOnlineItemData.eTag;
						
						// attempt the session upload using the session data provided
						uploadResponse = performSessionFileUpload(uploadFileOneDriveApiInstance, thisFileSizeLocal, uploadSessionData, threadUploadSessionFilePath);
					} catch (OneDriveException exception) {
						// Handle all other HTTP status codes
						// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
						// Display what the error is
						displayOneDriveErrorMessage(exception.msg, thisFunctionName);
						
					} catch (FileException e) {
						addLogEntry("DEBUG TO REMOVE: Modified file upload FileException Handling (Perform the Upload using the session)");
						displayFileSystemErrorMessage(e.msg, thisFunctionName);
					}
				} else {
					// Create session Upload URL failed
					if (debugLogging) {addLogEntry("Unable to upload modified file as the creation of the upload session URL failed", ["debug"]);}
				}
			}
		} else {
			// We are in a --dry-run scenario
			uploadResponse = createFakeResponse(localFilePath);
		}
		
		// Debug Log the modified upload response
		if (debugLogging) {addLogEntry("Modified File Upload Response: " ~ to!string(uploadResponse), ["debug"]);}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		uploadFileOneDriveApiInstance.releaseCurlEngine();
		uploadFileOneDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// Return JSON
		return uploadResponse;
	}
		
	// Query the OneDrive API using the provided driveId to get the latest quota details
	string[3][] getRemainingFreeSpaceOnline(string driveId) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Get the quota details for this driveId
		// Quota details are ONLY available for the main default driveId, as the OneDrive API does not provide quota details for shared folders
		JSONValue currentDriveQuota;
		bool quotaRestricted = false; // Assume quota is not restricted unless "remaining" is missing
		bool quotaAvailable = false;
		long quotaRemainingOnline = 0;
		string[3][] result;
		OneDriveApi getCurrentDriveQuotaApiInstance;

		// Ensure that we have a valid driveId to query
		if (driveId.empty) {
			// No 'driveId' was provided, use the application default
			driveId = appConfig.defaultDriveId;
		}

		// Try and query the quota for the provided driveId
		try {
			// Create a new OneDrive API instance
			getCurrentDriveQuotaApiInstance = new OneDriveApi(appConfig);
			getCurrentDriveQuotaApiInstance.initialise();
			if (debugLogging) {addLogEntry("Seeking available quota for this drive id: " ~ driveId, ["debug"]);}
			currentDriveQuota = getCurrentDriveQuotaApiInstance.getDriveQuota(driveId);
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			getCurrentDriveQuotaApiInstance.releaseCurlEngine();
			getCurrentDriveQuotaApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			
		} catch (OneDriveException e) {
			if (debugLogging) {addLogEntry("currentDriveQuota = onedrive.getDriveQuota(driveId) generated a OneDriveException", ["debug"]);}
			// If an exception occurs, it's unclear if quota is restricted, but quota details are not available
			quotaRestricted = true; // Considering restricted due to failure to access
			// Return result
			result ~= [to!string(quotaRestricted), to!string(quotaAvailable), to!string(quotaRemainingOnline)];
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			getCurrentDriveQuotaApiInstance.releaseCurlEngine();
			getCurrentDriveQuotaApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			return result;
		}
		
		// Validate that currentDriveQuota is a JSON value
		if (currentDriveQuota.type() == JSONType.object && "quota" in currentDriveQuota) {
			// Response from API contains valid data
			// If 'personal' accounts, if driveId == defaultDriveId, then we will have data
			// If 'personal' accounts, if driveId != defaultDriveId, then we will not have quota data
			// If 'business' accounts, if driveId == defaultDriveId, then we will have data
			// If 'business' accounts, if driveId != defaultDriveId, then we will have data, but it will be a 0 value
			if (debugLogging) {addLogEntry("Quota Details: " ~ to!string(currentDriveQuota), ["debug"]);}
			JSONValue quota = currentDriveQuota["quota"];
			
			if ("remaining" in quota) {
				// Issue #2806
				// If this is a negative value, quota["remaining"].integer can potentially convert to a huge positive number. Convert a different way.
				string tempQuotaRemainingOnlineString;
				// is quota["remaining"] an integer type?
				if (quota["remaining"].type() == JSONType.integer) {
					// extract as integer and convert to string
					tempQuotaRemainingOnlineString = to!string(quota["remaining"].integer);
				} 
				
				// is quota["remaining"] an string type?
				if (quota["remaining"].type() == JSONType.string) {
					// extract as string
					tempQuotaRemainingOnlineString = quota["remaining"].str;
				}
				
				// Fallback
				if (tempQuotaRemainingOnlineString.empty) {
					// tempQuotaRemainingOnlineString was not set, set to zero as a string
					tempQuotaRemainingOnlineString = "0";
				}
				
				// Update quotaRemainingOnline to use the converted string value
				quotaRemainingOnline = to!long(tempQuotaRemainingOnlineString);
			
				// Set the applicable 'quotaAvailable' value
				quotaAvailable = quotaRemainingOnline > 0;
				
				// If "remaining" is present but its value is <= 0, it's not restricted but exhausted
				if (quotaRemainingOnline <= 0) {
					if (appConfig.accountType == "personal") {
						addLogEntry("ERROR: OneDrive account currently has zero space available. Please free up some space online or purchase additional capacity.");
					} else { // Assuming 'business' or 'sharedLibrary'
						if (verboseLogging) {addLogEntry("WARNING: OneDrive quota information is being restricted or providing a zero value. Please fix by speaking to your OneDrive / Office 365 Administrator." , ["verbose"]);}
					}
				}
			} else {
				// "remaining" not present, indicating restricted quota information
				quotaRestricted = true;
				
				// what sort of account type is this?
				if (appConfig.accountType == "personal") {
					if (verboseLogging) {addLogEntry("ERROR: OneDrive quota information is missing. Your OneDrive account potentially has zero space available. Please free up some space online.", ["verbose"]);}
				} else {
					// quota details not available
					if (verboseLogging) {addLogEntry("WARNING: OneDrive quota information is being restricted. Please fix by speaking to your OneDrive / Office 365 Administrator.", ["verbose"]);}
				}
			}
		} else {
			// When valid quota details are not fetched
			if (verboseLogging) {addLogEntry("Failed to fetch or query quota details for OneDrive Drive ID: " ~ driveId, ["verbose"]);}
			quotaRestricted = true; // Considering restricted due to failure to interpret
		}

		// What was the determined available quota?
		if (debugLogging) {addLogEntry("Reported Available Online Quota for driveID '" ~ driveId ~ "': " ~ to!string(quotaRemainingOnline), ["debug"]);}
		
		// Return result
		result ~= [to!string(quotaRestricted), to!string(quotaAvailable), to!string(quotaRemainingOnline)];
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// return new drive array data
		return result;
	}

	// Perform a filesystem walk to uncover new data to upload to OneDrive
	void scanLocalFilesystemPathForNewData(string path) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Cleanup array memory before we start adding files
		pathsToCreateOnline = [];
		newLocalFilesToUploadToOneDrive = [];
		
		// Perform a filesystem walk to uncover new data
		scanLocalFilesystemPathForNewDataToUpload(path);
		
		// Create new directories online that has been identified
		processNewDirectoriesToCreateOnline();
		
		// Upload new data that has been identified
		processNewLocalItemsToUpload();
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}

	// Scan the local filesystem for new data to upload
	void scanLocalFilesystemPathForNewDataToUpload(string path) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// To improve logging output for this function, what is the 'logical path' we are scanning for file & folder differences?
		string logPath;
		if (path == ".") {
			// get the configured sync_dir
			logPath = buildNormalizedPath(appConfig.getValueString("sync_dir"));
		} else {
			// use what was passed in
			if (!appConfig.getValueBool("monitor")) {
				logPath = buildNormalizedPath(appConfig.getValueString("sync_dir")) ~ "/" ~ path;
			} else {
				logPath = path;
			}
		}
		
		// Log the action that we are performing, however only if this is a directory
		if (exists(path)) {
			if (isDir(path)) {
				if (!appConfig.suppressLoggingOutput) {
					if (!cleanupLocalFiles) {
						addProcessingLogHeaderEntry("Scanning the local file system '" ~ logPath ~ "' for new data to upload", appConfig.verbosityCount);
					} else {
						addProcessingLogHeaderEntry("Scanning the local file system '" ~ logPath ~ "' for data to cleanup", appConfig.verbosityCount);
						// Set the cleanup flag
						cleanupDataPass = true;
					}
				}
			}
		}
		
		SysTime startTime;
		if (debugLogging) {
			startTime = Clock.currTime();
			addLogEntry("Starting Filesystem Walk (Local Time): " ~ to!string(startTime), ["debug"]);
		}
		
		// Add a processing '.' if this is a directory we are scanning
		if (exists(path)) {
			if (isDir(path)) {
				if (!appConfig.suppressLoggingOutput) {
					if (appConfig.verbosityCount == 0) {
						addProcessingDotEntry();
					}
				}
			}
		}
		
		// Perform the filesystem walk of this path, building an array of new items to upload
		scanPathForNewData(path);
		// Reset flag
		cleanupDataPass = false;
		
		// Close processing '.' if this is a directory we are scanning
		if (exists(path)) {
			if (isDir(path)) {
				if (appConfig.verbosityCount == 0) {
					if (!appConfig.suppressLoggingOutput) {
						// Close out the '....' being printed to the console
						completeProcessingDots();
					}
				}
			}
		}
		
		// To finish off the processing items, this is needed to reflect this in the log
		if (debugLogging) {
			addLogEntry(debugLogBreakType1, ["debug"]);
			// finish filesystem walk time
			SysTime finishTime = Clock.currTime();
			addLogEntry("Finished Filesystem Walk (Local Time): " ~ to!string(finishTime), ["debug"]);
			// duration
			Duration elapsedTime = finishTime - startTime;
			addLogEntry("Elapsed Time Filesystem Walk:          " ~ to!string(elapsedTime), ["debug"]);
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Ensure we have a full list of unique paths to create online
	void addPathToCreateOnline(string pathToAdd) {
	
		// Is this a valid path to add?
		// The requested directory to create was not found on OneDrive - creating remote directory: ./.
		// 		OneDrive generated an error when creating this path: ./.
		// 		ERROR: Microsoft OneDrive API returned an error with the following message:
		// 		  Error Message:       HTTP request returned status code 400 (Bad Request)
		// 		  Error Reason:        Invalid request
		// 		  Error Code:          invalidRequest
		// 		  Error Timestamp:     2025-05-02T20:31:46
		// 		  API Request ID:      23c2e2cd-6968-4a99-ac80-f9da786a18fd
		// 		  Calling Function:    syncEngine.createDirectoryOnline()

		// Is this a valid path to add?
		if ((pathToAdd == ".")||(pathToAdd == "./.")) {
			// matches paths we should not attempt to create online
			if (debugLogging) {addLogEntry("attempted to add as path to create online - rejecting: " ~ pathToAdd, ["debug"]);}
		
			// We can never add or create online the OneDrive 'root'
			return;
		}
	
		// Only add unique paths
		if (!pathsToCreateOnline.canFind(pathToAdd)) {
			// Add this unique path to the created online
			pathsToCreateOnline ~= pathToAdd;
		}
	}
	
	// Create new directories online
	void processNewDirectoriesToCreateOnline() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// This list of local paths that need to be created online
		string[] uniquePathsToCreateOnline;
		
		// Are there any new local directories to create online?
		if (!pathsToCreateOnline.empty) {
			// There are new directories to create online
			addLogEntry("New directories to create on Microsoft OneDrive: " ~ to!string(pathsToCreateOnline.length));
			if (debugLogging) {addLogEntry("pathsToCreateOnline = " ~ to!string(pathsToCreateOnline), ["debug"]);}
			
			// Process 'pathsToCreateOnline' into each array element, then create each path based on path segments
			foreach (fullPath; pathsToCreateOnline) {
				// Normalise path and strip leading "./" if present
				string normalised = fullPath;
				if (normalised.startsWith("./"))
					normalised = normalised[2 .. $];
				if (normalised.endsWith("/"))
					normalised = normalised[0 .. $ - 1];

				auto segments = normalised.split("/").filter!(s => !s.empty).array;
				string pathToCreate = ".";

				foreach (i; 0 .. segments.length) {
					pathToCreate = buildPath(pathToCreate, segments[i]);
					
					// Only add unique paths to avoid duplication of the same path creation request
					if (!uniquePathsToCreateOnline.canFind(pathToCreate)) {
						// Add this unique path to the created online
						uniquePathsToCreateOnline ~= pathToCreate;
					}
				}
			}
		}
		
		// Now that all the paths have been rationalised and potential duplicate creation requests filtered out, create the paths online
		if (debugLogging) {addLogEntry("uniquePathsToCreateOnline = " ~ to!string(uniquePathsToCreateOnline), ["debug"]);}
		
		// For each path in the array, attempt to create this online
		foreach (onlinePathToCreate; uniquePathsToCreateOnline) {
			try {
				// Try and create the required path online
				createDirectoryOnline(onlinePathToCreate);
			} catch (Exception e) {
				addLogEntry("ERROR: Failed to create directory online: " ~ onlinePathToCreate ~ " => " ~ e.msg);
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Upload new data that has been identified to Microsoft OneDrive
	void processNewLocalItemsToUpload() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}

		// Are there any new local items to upload?
		if (!newLocalFilesToUploadToOneDrive.empty) {
			// There are elements to upload
			addLogEntry("New items to upload to Microsoft OneDrive: " ~ to!string(newLocalFilesToUploadToOneDrive.length) );
			
			// Reset totalDataToUpload
			totalDataToUpload = 0;
			
			// How much data do we need to upload? This is important, as, we need to know how much data to determine if all the files can be uploaded
			foreach (uploadFilePath; newLocalFilesToUploadToOneDrive) {
				// validate that the path actually exists so that it can be counted
				if (exists(uploadFilePath)) {
					totalDataToUpload = totalDataToUpload + getSize(uploadFilePath);
				}
			}
			
			// How much data is there to upload
			if (verboseLogging) {
				if (totalDataToUpload < 1024) {
					// Display as Bytes to upload
					addLogEntry("Total New Data to Upload:        " ~ to!string(totalDataToUpload) ~ " Bytes", ["verbose"]);
				} else {
					if ((totalDataToUpload > 1024) && (totalDataToUpload < 1048576)) {
						// Display as KB to upload
						addLogEntry("Total New Data to Upload:        " ~ to!string((totalDataToUpload / 1024)) ~ " KB", ["verbose"]);
					} else {
						// Display as MB to upload
						addLogEntry("Total New Data to Upload:        " ~ to!string((totalDataToUpload / 1024 / 1024)) ~ " MB", ["verbose"]);
					}
				}
			}
			
			// How much space is available 
			// The file, could be uploaded to a shared folder, which, we are not tracking how much free space is available there ... 
			// Iterate through all the drives we have cached thus far, that we know about
			if (debugLogging) {
				foreach (driveId, driveDetails; onlineDriveDetails) {
					// Log how much space is available for each driveId
					addLogEntry("Current Available Space Online (" ~ driveId ~ "): " ~ to!string((driveDetails.quotaRemaining / 1024 / 1024)) ~ " MB", ["debug"]);
				}
			}
			
			// Perform the upload
			uploadNewLocalFileItems();
			
			// Cleanup array memory after uploading all files
			newLocalFilesToUploadToOneDrive = [];
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Scan this path for new data
	void scanPathForNewData(string path) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// Add a processing '.'
		if (exists(path)) {
			if (isDir(path)) {
				if (!appConfig.suppressLoggingOutput) {
					if (appConfig.verbosityCount == 0) {
						addProcessingDotEntry();
					}
				}
			}
		}

		long maxPathLength;
		long pathWalkLength;
		
		// Add this logging break to assist with what was checked for each path
		if (path != ".") {
			if (debugLogging) {addLogEntry(debugLogBreakType1, ["debug"]);}
		}
		
		// https://support.microsoft.com/en-us/help/3125202/restrictions-and-limitations-when-you-sync-files-and-folders
		// If the path is greater than allowed characters, then one drive will return a '400 - Bad Request'
		// Need to ensure that the URI is encoded before the check is made:
		// - 400 Character Limit for OneDrive Business / Office 365
		// - 430 Character Limit for OneDrive Personal
		
		// Configure maxPathLength based on account type
		if (appConfig.accountType == "personal") {
			// Personal Account
			maxPathLength = 430;
		} else {
			// Business Account / Office365 / SharePoint
			maxPathLength = 400;
		}
		
		// OneDrive Business Shared Files Handling - if we make a 'backup' locally of a file shared with us (because we modified it, and then maybe did a --resync), it will be treated as a new file to upload ...
		// The issue here is - the 'source' was a shared file - we may not even have permission to upload a 'renamed' file to the shared file's parent folder
		// In this case, we need to skip adding this new local file - we do not upload it (we cant , and we should not)
		if (appConfig.accountType == "business") {
			// Check appConfig.configuredBusinessSharedFilesDirectoryName against 'path'
			if (canFind(path, baseName(appConfig.configuredBusinessSharedFilesDirectoryName))) {
				// Log why this path is being skipped
				addLogEntry("Skipping scanning path for new files as this is reserved for OneDrive Business Shared Files: " ~ path, ["info"]);
				return;
			}
		}
				
		// A short lived item that has already disappeared will cause an error - is the path still valid?
		if (!exists(path)) {
			addLogEntry("Skipping path - path has disappeared: " ~ path);
			return;
		}
		
		// Calculate the path length by walking the path and catch any UTF-8 sequence errors at the same time
		// https://github.com/skilion/onedrive/issues/57
		// https://github.com/abraunegg/onedrive/issues/487
		// https://github.com/abraunegg/onedrive/issues/1192
		try {
			pathWalkLength = path.byGrapheme.walkLength;
		} catch (std.utf.UTFException e) {
			// Path contains characters which generate a UTF exception
			addLogEntry("Skipping item - invalid UTF sequence: " ~ path, ["info", "notify"]);
			if (debugLogging) {addLogEntry("  Error Reason:" ~ e.msg, ["debug"]);}
			return;
		}
		
		// Is the path length is less than maxPathLength
		if (pathWalkLength < maxPathLength) {
			// Is this path unwanted
			bool unwanted = false;
			
			// First check of this item - if we are in a --dry-run scenario, we may have 'fake deleted' this path
			// thus, the entries are not in the dry-run DB copy, thus, at this point the client thinks that this is an item to upload
			// Check this 'path' for an entry in pathFakeDeletedArray - if it is there, this is unwanted
			if (dryRun) {
				// Is this path in the array of fake deleted items? If yes, return early, nothing else to do, save processing
				if (canFind(pathFakeDeletedArray, path)) return;
			}
			
			// Check if item if found in database
			bool itemFoundInDB = pathFoundInDatabase(path);
			
			// If the item is already found in the database, it is redundant to perform these checks
			if (!itemFoundInDB) {
				// This not a Client Side Filtering check, nor a Microsoft Check, but is a sanity check that the path provided is UTF encoded correctly
				// Check the std.encoding of the path against: Unicode 5.0, ASCII, ISO-8859-1, ISO-8859-2, WINDOWS-1250, WINDOWS-1251, WINDOWS-1252
				if (!unwanted) {
					if(!isValid(path)) {
						// Path is not valid according to https://dlang.org/phobos/std_encoding.html
						addLogEntry("Skipping item - invalid character encoding sequence: " ~ path, ["info", "notify"]);
						unwanted = true;
					}
				}
				
				// Check this path against the Client Side Filtering Rules
				// - check_nosync
				// - skip_dotfiles
				// - skip_symlinks
				// - skip_file
				// - skip_dir
				// - sync_list
				// - skip_size
				if (!unwanted) {
					// If this is not the cleanup data pass when using --download-only --cleanup-local-files we dont want to exclude files we need to delete locally when using 'sync_list'
					if (!cleanupDataPass) {
						unwanted = checkPathAgainstClientSideFiltering(path);
					}
				}
				
				// Check this path against the Microsoft Naming Conventions & Restrictions
				// - Check path against Microsoft OneDrive restriction and limitations about Windows naming for files and folders
				// - Check path for bad whitespace items
				// - Check path for HTML ASCII Codes
				// - Check path for ASCII Control Codes
				if (!unwanted) {
					unwanted = checkPathAgainstMicrosoftNamingRestrictions(path);
				}
			}
			
			// Before we traverse this 'path', we need to make a last check to see if this was just excluded
			bool skipFolderTraverse = skipBusinessSharedFolder(path);
			
			if (!unwanted) {
				// At this point, this path, we want to scan for new data as it is not excluded
				if (isDir(path)) {
					// Was the path found in the database?
					if (!itemFoundInDB) {
						// Path not found in database when searching all drive id's
						if (!cleanupLocalFiles) {
							// --download-only --cleanup-local-files not used
							// Create this directory on OneDrive so that we can upload files to it
							// Add this path to an array so that the directory online can be created before we upload files
							if (debugLogging) {addLogEntry("Adding path to create online (directory inclusion): " ~ path, ["debug"]);}
							addPathToCreateOnline(path);
						} else {
							// we need to clean up this directory
							addLogEntry("Removing local directory as --download-only & --cleanup-local-files configured");
							// Remove any children of this path if they still exist
							// Resolve 'Directory not empty' error when deleting local files
							try {
								auto directoryEntries = dirEntries(path, SpanMode.depth, false);
								foreach (DirEntry child; directoryEntries) {
									// what sort of child is this?
									if (isDir(child.name)) {
										addLogEntry("Removing local directory: " ~ child.name);
									} else {
										addLogEntry("Removing local file: " ~ child.name);
									}
									
									// are we in a --dry-run scenario?
									if (!dryRun) {
										// No --dry-run ... process local delete
										if (exists(child)) {
											try {
												attrIsDir(child.linkAttributes) ? rmdir(child.name) : remove(child.name);
											} catch (FileException e) {
												// display the error message
												displayFileSystemErrorMessage(e.msg, thisFunctionName);
											}
										}
									}
								}
								// Clear directoryEntries
								object.destroy(directoryEntries);
								
								// Remove the path now that it is empty of children
								addLogEntry("Removing local directory: " ~ path);
								// are we in a --dry-run scenario?
								if (!dryRun) {
									// No --dry-run ... process local delete
									if (exists(path)) {
									
										try {
											rmdirRecurse(path);
										} catch (FileException e) {
											// display the error message
											displayFileSystemErrorMessage(e.msg, thisFunctionName);
										}
										
									}
								}
							} catch (FileException e) {
								// display the error message
								displayFileSystemErrorMessage(e.msg, thisFunctionName);
								
								// Display function processing time if configured to do so
								if (appConfig.getValueBool("display_processing_time") && debugLogging) {
									// Combine module name & running Function
									displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
								}
								
								// return as there was an error
								return;
							}
						}
					}

					// Do we actually traverse this path?
					if (!skipFolderTraverse) {
						// Try and access this directory and any path below
						if (exists(path)) {
							try {
								auto directoryEntries = dirEntries(path, SpanMode.shallow, false);
								foreach (DirEntry entry; directoryEntries) {
									string thisPath = entry.name;
									scanPathForNewData(thisPath);
								}
								// Clear directoryEntries
								object.destroy(directoryEntries);
							} catch (FileException e) {
								// display the error message
								displayFileSystemErrorMessage(e.msg, thisFunctionName);
								
								// Display function processing time if configured to do so
								if (appConfig.getValueBool("display_processing_time") && debugLogging) {
									// Combine module name & running Function
									displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
								}
								
								// return as there was an error
								return;
							}
						}
					}
				} else {
					// https://github.com/abraunegg/onedrive/issues/984
					// path is not a directory, is it a valid file?
					// pipes - whilst technically valid files, are not valid for this client
					//  prw-rw-r--.  1 user user    0 Jul  7 05:55 my_pipe
					if (isFile(path)) {
						// Is the file a '.nosync' file?
						if (canFind(path, ".nosync")) {
							if (debugLogging) {addLogEntry("Skipping .nosync file", ["debug"]);}
							
							// Display function processing time if configured to do so
							if (appConfig.getValueBool("display_processing_time") && debugLogging) {
								// Combine module name & running Function
								displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
							}
							
							// return as there was an error
							return;
						}
					
						// Was the file found in the database?
						if (!itemFoundInDB) {
							// File not found in database when searching all drive id's
							// Do we upload the file or clean up the file?
							if (!cleanupLocalFiles) {
								// --download-only --cleanup-local-files not used
								
								// Ensure this directory on OneDrive so that we can upload files to it
								// Add this path to an array so that the directory online can be created before we upload files
								string parentPath = dirName(path);
								if (debugLogging) {addLogEntry("Adding parental path to create online (file inclusion): " ~ parentPath, ["debug"]);}
								addPathToCreateOnline(parentPath);
								
								// Add this path as a file we need to upload
								if (debugLogging) {addLogEntry("OneDrive Client flagging to upload this file to Microsoft OneDrive: " ~ path, ["debug"]);}
								newLocalFilesToUploadToOneDrive ~= path;
							} else {
								// we need to clean up this file
								addLogEntry("Removing local file as --download-only & --cleanup-local-files configured");
								// are we in a --dry-run scenario?
								addLogEntry("Removing local file: " ~ path);
								if (!dryRun) {
									// No --dry-run ... process local file delete
									safeRemove(path);
								}
							}
						}
					} else {
						// path is not a valid file
						addLogEntry("Skipping item - item is not a valid file: " ~ path, ["info", "notify"]);
					}
				}
			} else {
				// Issue #3126 - https://github.com/abraunegg/onedrive/discussions/3126
				// At this point, this path that we want to scan for new data has been excluded .. we may have an include 'sync_list' rule for a subfolder of this excluded parent ...
				// If the data is created online, this is not usually a problem, but essentially if we create new data locally, in a folder we are expecting to included by an existing configuration,
				// unless we actually scan the entire tree, including those directories that are excluded, we are not going to detect the new locally added data in a parent that has been excluded, 
				// but the child content has to be included
				if (isDir(path)) {
					// Do we actually traverse this path?
					if (!skipFolderTraverse) {
						// Not a Business Shared Folder that must not be traversed if 'sync_business_shared_folders' is not enabled
						// Was this path excluded by the 'sync_list' exclusion process
						if (syncListDirExcluded) {
							// yes .. this parent path was excluded by the 'sync_list' ... we need to scan this path for potential new data that may be included
							bool parentalInclusionSyncListRule = selectiveSync.isSyncListPrefixMatch(path);
							bool syncListAnywhereInclusionRulesExist = selectiveSync.syncListAnywhereInclusionRulesExist();
							bool mustTraversePath = false;
							
							if ((parentalInclusionSyncListRule) || (syncListAnywhereInclusionRulesExist)) {
								mustTraversePath = true;
							}
							
							// Log what we are testing
							if (debugLogging) {
								addLogEntry("Local path was excluded by 'sync_list' but is this in anyway included in a specific 'inclusion' rule?", ["debug"]);
								// Is this path in the 'sync_list' inclusion path array?
								addLogEntry("Testing path against the specific 'sync_list' inclusion rules: " ~ path, ["debug"]);
								addLogEntry("Should we traverse this local path to scan for new data: " ~ to!string(mustTraversePath), ["debug"]);
								addLogEntry(" - parentalInclusionSyncListRule: " ~ to!string(parentalInclusionSyncListRule), ["debug"]);
								addLogEntry(" - syncListAnywhereInclusionRulesExist:    " ~ to!string(syncListAnywhereInclusionRulesExist), ["debug"]);
							}
							
							// Was traversal of this excluded path triggered?
							if (mustTraversePath) {
								// We must traverse this path .. 
								if (verboseLogging) {
									// Why ...
									if (syncListAnywhereInclusionRulesExist) {
										addLogEntry("Bypassing 'sync_list' exclusion to scan directory for potential new data that may be included due to 'sync_list' anywhere rule existence", ["verbose"]);
									} else {
										addLogEntry("Bypassing 'sync_list' exclusion to scan directory for potential new data that may be included", ["verbose"]);
									}
								}
							
								// Try and go through the excluded directory path
								try {
									auto directoryEntries = dirEntries(path, SpanMode.shallow, false);
									foreach (DirEntry entry; directoryEntries) {
										string thisPath = entry.name;
										scanPathForNewData(thisPath);
									}
									// Clear directoryEntries
									object.destroy(directoryEntries);
								} catch (FileException e) {
									// display the error message
									displayFileSystemErrorMessage(e.msg, thisFunctionName);
									
									// Display function processing time if configured to do so
									if (appConfig.getValueBool("display_processing_time") && debugLogging) {
										// Combine module name & running Function
										displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
									}
									
									// return as there was an error
									return;
								}
							}
						}
					}
				}
			}
		} else {
			// This path was skipped - why?
			addLogEntry("Skipping item '" ~ path ~ "' due to the full path exceeding " ~ to!string(maxPathLength) ~ " characters (Microsoft OneDrive limitation)", ["info", "notify"]);
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Do we skip this path as it might be an Online Business Shared Folder
	bool skipBusinessSharedFolder(string path) {
		// Is this a business account?
		if (appConfig.accountType == "business") {
			// search businessSharedFoldersOnlineToSkip for this path
			if (canFind(businessSharedFoldersOnlineToSkip, path)) {
				// This path was skipped - why?
				addLogEntry("Skipping item '" ~ path ~ "' due to this path matching an existing online Business Shared Folder name", ["info", "notify"]);
				addLogEntry("To sync this Business Shared Folder, consider enabling 'sync_business_shared_folders' within your application configuration.", ["info"]);
				return true;
			}
		}
	
		// return value
		return false;
	}
	
	// Handle a single file inotify trigger when using --monitor
	void handleLocalFileTrigger(string[] changedLocalFilesToUploadToOneDrive) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Is this path a new file or an existing one?
		// Normally we would use pathFoundInDatabase() to calculate, but we need 'databaseItem' as well if the item is in the database
		foreach (localFilePath; changedLocalFilesToUploadToOneDrive) {
			try {
				Item databaseItem;
				bool fileFoundInDB = false;
				
				foreach (driveId; onlineDriveDetails.keys) {
					if (itemDB.selectByPath(localFilePath, driveId, databaseItem)) {
						fileFoundInDB = true;
						
						// Display function processing time if configured to do so
						if (appConfig.getValueBool("display_processing_time") && debugLogging) {
							// Combine module name & running Function
							displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
						}
						
						// file found, search no more
						break;
					}
				}
				
				// Was the file found in the database?
				if (!fileFoundInDB) {
					// This is a new file as it is not in the database
					// Log that the file has been added locally
					if (verboseLogging) {addLogEntry("[M] New local file added: " ~ localFilePath, ["verbose"]);}
					scanLocalFilesystemPathForNewDataToUpload(localFilePath);
				} else {
					// This is a potentially modified file, needs to be handled as such. Is the item truly modified?
					if (!testFileHash(localFilePath, databaseItem)) {
						// The local file failed the hash comparison test - there is a data difference
						// Log that the file has changed locally
						if (verboseLogging) {addLogEntry("[M] Local file changed: " ~ localFilePath, ["verbose"]);}
						// Add the modified item to the array to upload
						uploadChangedLocalFileToOneDrive([databaseItem.driveId, databaseItem.id, localFilePath]);
					}
				}
			} catch(Exception e) {
				addLogEntry("Cannot upload file changes/creation: " ~ e.msg, ["info", "notify"]);
			}
		}
		processNewLocalItemsToUpload();
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Query the database to determine if this path is within the existing database
	bool pathFoundInDatabase(string searchPath) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Check if this path in the database
		Item databaseItem;
		if (debugLogging) {addLogEntry("Search DB for this path: " ~ searchPath, ["debug"]);}
		
		foreach (driveId; onlineDriveDetails.keys) {
			if (itemDB.selectByPath(searchPath, driveId, databaseItem)) {
				if (debugLogging) {addLogEntry("DB Record for search path: " ~ to!string(databaseItem), ["debug"]);}
				
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
				
				return true; // Early exit on finding the path in the DB
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		return false; // Return false if path is not found in any drive
	}
	
	// Create a new directory online on OneDrive
	// - Test if we can get the parent path details from the database, otherwise we need to search online
	//   for the path flow and create the folder that way
	void createDirectoryOnline(string thisNewPathToCreate) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Is this a valid path to create?
		// We need to avoid this sort of error:
		//
		//		OneDrive generated an error when creating this path: .

		//		ERROR: Microsoft OneDrive API returned an error with the following message:
		//		  Error Message:       HTTP request returned status code 400 (Bad Request)
		//		  Error Reason:        Invalid request
		//		  Error Code:          invalidRequest
		//		  Error Timestamp:     2025-08-01T21:08:26
		//		  API Request ID:      dca77bd6-1e9a-432a-bc6c-1c6b5380745d
		if (isRootEquivalent(thisNewPathToCreate)) return;
		
		// Log what path we are attempting to create online
		if (verboseLogging) {addLogEntry("OneDrive Client requested to create this directory online: " ~ thisNewPathToCreate, ["verbose"]);}
		
		// Function variables
		Item parentItem;
		JSONValue onlinePathData;
		
		// Special Folder Handling: Do NOT create the folder online if it is being used for OneDrive Business Shared Files
		// These are local copy files, in a self created directory structure which is not to be replicated online
		// Check appConfig.configuredBusinessSharedFilesDirectoryName against 'thisNewPathToCreate'
		if (canFind(thisNewPathToCreate, baseName(appConfig.configuredBusinessSharedFilesDirectoryName))) {
			// Log why this is being skipped
			addLogEntry("Skipping creating '" ~ thisNewPathToCreate ~ "' as this path is used for handling OneDrive Business Shared Files", ["info", "notify"]);
			
			// Display function processing time if configured to do so
			if (appConfig.getValueBool("display_processing_time") && debugLogging) {
				// Combine module name & running Function
				displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
			}

			// return early as skipping
			return;
		}
		
		// Create a new API Instance for this thread and initialise it
		OneDriveApi createDirectoryOnlineOneDriveApiInstance;
		createDirectoryOnlineOneDriveApiInstance = new OneDriveApi(appConfig);
		createDirectoryOnlineOneDriveApiInstance.initialise();
		
		// What parent path to use?
		string parentPath = dirName(thisNewPathToCreate); // will be either . or something else
		
		// Configure the parentItem by if this is the account 'root' use the root details, or search the database for the parent details
		if (parentPath == ".") {
			// Parent path is '.' which is the account root
			// Use client defaults
			parentItem.driveId = appConfig.defaultDriveId;
			parentItem.id = appConfig.defaultRootId;
		} else {
			// Query the parent path online
			if (debugLogging) {addLogEntry("Attempting to query Local Database for this parent path: " ~ parentPath, ["debug"]);}

			// Attempt a 2 step process to work out where to create the directory
			// Step 1: Query the DB first for the parent path, to try and avoid an API call
			// Step 2: Query online as last resort
			
			// Step 1: Check if this parent path in the database
			Item databaseItem;
			bool parentPathFoundInDB = false;
			
			foreach (driveId; onlineDriveDetails.keys) {
				// driveId comes from the DB .. trust it is has been validated
				if (debugLogging) {addLogEntry("Query DB with this driveID for the Parent Path: " ~ driveId, ["debug"]);}
				
				// Query the database for this parent path using each driveId that we know about
				if (itemDB.selectByPath(parentPath, driveId, databaseItem)) {
					parentPathFoundInDB = true;
					if (debugLogging) {
						addLogEntry("Parent databaseItem: " ~ to!string(databaseItem), ["debug"]);
						addLogEntry("parentPathFoundInDB: " ~ to!string(parentPathFoundInDB), ["debug"]);
					}
					
					// Set parentItem to the item returned from the database
					parentItem = databaseItem;
				}
			}
			
			// After querying all DB entries for each driveID for the parent path, what are the details in parentItem?
			if (debugLogging) {addLogEntry("Parent parentItem after DB Query exhausted: " ~ to!string(parentItem), ["debug"]);}

			// Step 2: Query for the path online if NOT found in the local database
			if (!parentPathFoundInDB) {
				// parent path not found in database
				try {
					if (debugLogging) {addLogEntry("Attempting to query OneDrive Online for this parent path as path not found in local database: " ~ parentPath, ["debug"]);}
					onlinePathData = createDirectoryOnlineOneDriveApiInstance.getPathDetails(parentPath);
					if (debugLogging) {addLogEntry("Online Parent Path Query Response: " ~ to!string(onlinePathData), ["debug"]);}
					
					// Make the parentItem from the online data
					parentItem = makeItem(onlinePathData);
					
					// Before we 'save' this item to the database, is the parent of this parent in the database?
					// We need to go and check the grandparent item for this parent item
					Item grandparentDatabaseItem;
					bool grandparentInDatabase = itemDB.selectById(onlinePathData["parentReference"]["driveId"].str, onlinePathData["parentReference"]["id"].str, grandparentDatabaseItem);
					
					// Is the 'grandparent' in the database?
					if (!grandparentInDatabase) {
						// No ..
						string grandParentPath = dirName(parentPath);
						// create/add grandparent path online, add to database
						createDirectoryOnline(grandParentPath);
					}
					
					// Save parent item to the database
					saveItem(onlinePathData);
					
				} catch (OneDriveException exception) {
					if (exception.httpStatusCode == 404) {
						// Parent does not exist ... need to create parent
						if (debugLogging) {addLogEntry("Parent path does not exist online: " ~ parentPath, ["debug"]);}
						createDirectoryOnline(parentPath);
						// no return here as we need to continue, but need to re-query the OneDrive API to get the right parental details now that they exist
						onlinePathData = createDirectoryOnlineOneDriveApiInstance.getPathDetails(parentPath);
						parentItem = makeItem(onlinePathData);
					} else {
						// Default operation if not 408,429,503,504 errors
						// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
						// Display what the error is
						displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					}
				}
			}
		}
		
		// Make sure the full path does not exist online, this should generate a 404 response, to which then the folder will be created online
		try {
			// Try and query the OneDrive API for the path we need to create
			if (debugLogging) {
				addLogEntry("Attempting to query OneDrive API for this path: " ~ thisNewPathToCreate, ["debug"]);
				addLogEntry("parentItem details: " ~ to!string(parentItem), ["debug"]);
			}
			
			// Depending on the data within parentItem, will depend on what method we are using to search
			// A Shared Folder will be 'remote' so we need to check the remote parent id, rather than parentItem details
			Item queryItem;
			
			// If we are doing a normal sync, 'parentItem.type == ItemType.remote' comparison works
			// If we are doing a --local-first 'parentItem.type == ItemType.remote' fails as the returned object is not a remote item, but is remote based on the 'driveId'
			if (parentItem.type == ItemType.remote) {
				// This folder is a potential shared object
				if (debugLogging) {addLogEntry("ParentItem is a remote item object", ["debug"]);}
				
				// Is this a Personal Account Type or has 'sync_business_shared_items' been enabled?
				if ((appConfig.accountType == "personal") || (appConfig.getValueBool("sync_business_shared_items"))) {
					// Update the queryItem values
					queryItem.driveId = parentItem.remoteDriveId;
					queryItem.id = parentItem.remoteId;
				} else {
					// This is a shared folder location, but we are not a 'personal' account, and 'sync_business_shared_items' has not been enabled
					addLogEntry("ERROR: Unable to create directory online as 'sync_business_shared_items' is not enabled");
					
					// Display function processing time if configured to do so
					if (appConfig.getValueBool("display_processing_time") && debugLogging) {
						// Combine module name & running Function
						displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
					}
					
					// return as we cannot continue here
					return;
				}
			} else {
				// Use parent item for the query item
				if (debugLogging) {addLogEntry("Standard Query, use parentItem", ["debug"]);}
				queryItem = parentItem;
			}
			
			// Issue #3115 - Validate driveId length
			// What account type is this?
			if (appConfig.accountType == "personal") {
				// Issue #3336 - Convert driveId to lowercase before any test
				queryItem.driveId = transformToLowerCase(queryItem.driveId);
				
				// Test driveId length and validation if the driveId we are testing is not equal to appConfig.defaultDriveId
				if (queryItem.driveId != appConfig.defaultDriveId) {
					queryItem.driveId = testProvidedDriveIdForLengthIssue(queryItem.driveId);
				}
			}
			
			if (queryItem.driveId == appConfig.defaultDriveId) {
				// Use getPathDetailsByDriveId
				if (debugLogging) {addLogEntry("Selecting getPathDetailsByDriveId to query OneDrive API for path data", ["debug"]);}
				onlinePathData = createDirectoryOnlineOneDriveApiInstance.getPathDetailsByDriveId(queryItem.driveId, thisNewPathToCreate);
			} else {
				// Use searchDriveForPath to query OneDrive
				if (debugLogging) {addLogEntry("Selecting searchDriveForPath to query OneDrive API for path data", ["debug"]);}
				// If the queryItem.driveId is not our driveId - the path we are looking for will not be at the logical location that getPathDetailsByDriveId 
				// can use - as it will always return a 404 .. even if the path actually exists (which is the whole point of this test)
				// Search the queryItem.driveId for any folder name match that we are going to create, then compare response JSON items with queryItem.id
				// If no match, the folder we want to create does not exist at the location we are seeking to create it at, thus generate a 404
				onlinePathData = createDirectoryOnlineOneDriveApiInstance.searchDriveForPath(queryItem.driveId, baseName(thisNewPathToCreate));
				if (debugLogging) {addLogEntry("onlinePathData: " ~to!string(onlinePathData), ["debug"]);}
				
				// Process the response from searching the drive
				long responseCount = count(onlinePathData["value"].array);
				if (responseCount > 0) {
					// Search 'name' matches were found .. need to match these against queryItem.id
					bool foundDirectoryOnline = false;
					JSONValue foundDirectoryJSONItem;
					// Items were returned .. but is one of these what we are looking for?
					foreach (childJSON; onlinePathData["value"].array) {
						// Is this item not a file?
						if (!isFileItem(childJSON)) {
							Item thisChildItem = makeItem(childJSON);
							// Direct Match Check
							if ((queryItem.id == thisChildItem.parentId) && (baseName(thisNewPathToCreate) == thisChildItem.name)) {
								// High confidence that this child folder is a direct match we are trying to create and it already exists online
								if (debugLogging) {
									addLogEntry("Path we are searching for exists online (Direct Match): " ~ baseName(thisNewPathToCreate), ["debug"]);
									addLogEntry("childJSON: " ~ sanitiseJSONItem(childJSON), ["debug"]);
								}
								foundDirectoryOnline = true;
								foundDirectoryJSONItem = childJSON;
								break;
							}
							
							// Full Lower Case POSIX Match Check
							string childAsLower = toLower(childJSON["name"].str);
							string thisFolderNameAsLower = toLower(baseName(thisNewPathToCreate));
							
							// Child name check
							if (childAsLower == thisFolderNameAsLower) {	
								// This is a POSIX 'case in-sensitive match' ..... in folder name only
								// - Local item name has a 'case-insensitive match' to an existing item on OneDrive
								// The 'parentId' of this JSON object must match the parentId of where the folder was created
								// - why .. we might have the same folder name, but somewhere totally different
								
								if (queryItem.id == thisChildItem.parentId) {
									// Found the directory in the location, using case in-sensitive matching
									if (debugLogging) {
										addLogEntry("Path we are searching for exists online (POSIX 'case in-sensitive match'): " ~ baseName(thisNewPathToCreate), ["debug"]);
										addLogEntry("childJSON: " ~ sanitiseJSONItem(childJSON), ["debug"]);
									}
									foundDirectoryOnline = true;
									foundDirectoryJSONItem = childJSON;
									break;
								}
							}
						}
					}
					
					if (foundDirectoryOnline) {
						// Directory we are seeking was found online ...
						if (debugLogging) {addLogEntry("The directory we are seeking was found online by using searchDriveForPath ...", ["debug"]);}
						onlinePathData = foundDirectoryJSONItem;
					} else {
						// No 'search item matches found' - raise a 404 so that the exception handling will take over to create the folder
						throw new OneDriveException(404, "Name not found via search");
					}
				} else {
					// No 'search item matches found' - raise a 404 so that the exception handling will take over to create the folder
					throw new OneDriveException(404, "Name not found via search");
				}
			}
		} catch (OneDriveException exception) {
			if (exception.httpStatusCode == 404) {
				// This is a good error - it means that the directory to create 100% does not exist online
				// The directory was not found on the drive id we queried
				if (verboseLogging) {addLogEntry("The requested directory to create was not found on OneDrive - creating remote directory: " ~ thisNewPathToCreate, ["verbose"]);}
				
				// Build up the online create directory request
				string requiredDriveId;
				string requiredParentItemId;
				JSONValue createDirectoryOnlineAPIResponse;
				JSONValue newDriveItem = [
						"name": JSONValue(baseName(thisNewPathToCreate)),
						"folder": parseJSON("{}")
				];
				
				// Submit the creation request
				// Fix for https://github.com/skilion/onedrive/issues/356
				if (!dryRun) {
					try {
						// Attempt to create a new folder on the required driveId and parent item id
						// Is the item a Remote Object (Shared Folder) ?
						if (parentItem.type == ItemType.remote) {
							// Yes .. Shared Folder
							if (debugLogging) {addLogEntry("parentItem data: " ~ to!string(parentItem), ["debug"]);}
							requiredDriveId = parentItem.remoteDriveId;
							requiredParentItemId = parentItem.remoteId;
						} else {
							// Not a Shared Folder
							requiredDriveId = parentItem.driveId;
							requiredParentItemId = parentItem.id;
						}
						
						// Where are we creating this new folder?
						if (debugLogging) {
							addLogEntry("requiredDriveId:      " ~ requiredDriveId, ["debug"]);
							addLogEntry("requiredParentItemId: " ~ requiredParentItemId, ["debug"]);
							addLogEntry("newDriveItem JSON:    " ~ sanitiseJSONItem(newDriveItem), ["debug"]);
						}
					
						// Create the new folder
						createDirectoryOnlineAPIResponse = createDirectoryOnlineOneDriveApiInstance.createById(requiredDriveId, requiredParentItemId, newDriveItem);
						
						// Log that the directory was created
						addLogEntry("Successfully created the remote directory " ~ thisNewPathToCreate ~ " on Microsoft OneDrive");
						
						// Is the response a valid JSON object - validation checking done in saveItem, printing of the JSON object is done in saveItem()
						saveItem(createDirectoryOnlineAPIResponse);
						
					} catch (OneDriveException exception) {
						if (exception.httpStatusCode == 409) {
							// OneDrive API returned a 404 (far above) to say the directory did not exist
							// but when we attempted to create it, OneDrive responded that it now already exists with a 409
							if (verboseLogging) {addLogEntry("OneDrive reported that " ~ thisNewPathToCreate ~ " already exists .. OneDrive API race condition", ["verbose"]);}
							
							// Try to recover race condition by querying the parent's children for the folder we are trying to create
							createDirectoryOnlineAPIResponse = resolveOnlineCreationRaceCondition(requiredDriveId, requiredParentItemId, thisNewPathToCreate);
							
							// Log that the directory details were obtained
							addLogEntry("Successfully obtained the remote directory details " ~ thisNewPathToCreate ~ " from Microsoft OneDrive");
							
							// Is the response a valid JSON object - validation checking done in saveItem, printing of the JSON object is done in saveItem()
							saveItem(createDirectoryOnlineAPIResponse);
							
							// Shutdown this API instance, as we will create API instances as required, when required
							createDirectoryOnlineOneDriveApiInstance.releaseCurlEngine();
							// Free object and memory
							createDirectoryOnlineOneDriveApiInstance = null;
							// Perform Garbage Collection
							GC.collect();
						} else {
							// some other error from OneDrive was returned - display what it is
							addLogEntry("OneDrive generated an error when creating this path: " ~ thisNewPathToCreate);
							displayOneDriveErrorMessage(exception.msg, thisFunctionName);
							// Shutdown this API instance, as we will create API instances as required, when required
							createDirectoryOnlineOneDriveApiInstance.releaseCurlEngine();
							// Free object and memory
							createDirectoryOnlineOneDriveApiInstance = null;
							// Perform Garbage Collection
							GC.collect();
						}
						
						// Display function processing time if configured to do so
						if (appConfig.getValueBool("display_processing_time") && debugLogging) {
							// Combine module name & running Function
							displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
						}
						
						// return due to OneDriveException
						return;
					}
				} else {
					// Simulate a successful 'directory create' & save it to the dryRun database copy
					addLogEntry("Successfully created the remote directory " ~ thisNewPathToCreate ~ " on Microsoft OneDrive");
					// The simulated response has to pass 'makeItem' as part of saveItem
					auto fakeResponse = createFakeResponse(thisNewPathToCreate);
					// Save item to the database
					saveItem(fakeResponse);
				}
				
				// Shutdown this API instance, as we will create API instances as required, when required
				createDirectoryOnlineOneDriveApiInstance.releaseCurlEngine();
				// Free object and memory
				createDirectoryOnlineOneDriveApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
				
				// shutdown & return
				return;
			} else {
				// Default operation if not 408,429,503,504 errors
				// - 408,429,503,504 errors are handled as a retry within createDirectoryOnlineOneDriveApiInstance
				
				// If we get a 400 error, there is an issue creating this folder on Microsoft OneDrive for some reason
				// If the error is not 400, re-try, else fail
				if (exception.httpStatusCode != 400) {
					// Attempt a re-try
					createDirectoryOnline(thisNewPathToCreate);
				} else {
					// We cant create this directory online
					if (debugLogging) {addLogEntry("This folder cannot be created online: " ~ buildNormalizedPath(absolutePath(thisNewPathToCreate)), ["debug"]);}
				}
			}
		}
		
		// If we get to this point - onlinePathData = createDirectoryOnlineOneDriveApiInstance.getPathDetailsByDriveId(parentItem.driveId, thisNewPathToCreate) generated a 'valid' response ....
		// This means that the folder potentially exists online .. which is odd .. as it should not have existed
		if (onlinePathData.type() == JSONType.object) {
			// A valid object was responded with
			if (onlinePathData["name"].str == baseName(thisNewPathToCreate)) {
				// OneDrive 'name' matches local path name
				if (debugLogging) {
					addLogEntry("The path to query/search for online was found online", ["debug"]);
					addLogEntry(" onlinePathData via query/search: " ~ to!string(onlinePathData), ["debug"]);
				}
				
				// Now we know the location of this folder via query/search - go get the actual path details using the 'onlinePathData'
				Item onlineItem = makeItem(onlinePathData);
				
				// Fetch the real data in a consistent manner to ensure the JSON response contains the elements we are expecting
				JSONValue realOnlinePathData;
				
				// Get drive details for the provided driveId
				try {
					realOnlinePathData = createDirectoryOnlineOneDriveApiInstance.getPathDetailsById(onlineItem.driveId, onlineItem.id);
					if (debugLogging) {
						addLogEntry(" realOnlinePathData via getPathDetailsById call: " ~ to!string(realOnlinePathData), ["debug"]);
					}
				} catch (OneDriveException exception) {
					// An error was generated
					if (debugLogging) {addLogEntry("realOnlinePathData = createDirectoryOnlineOneDriveApiInstance.getPathDetailsById(onlineItem.driveId, onlineItem.id) generated a OneDriveException", ["debug"]);}
					
					// Default operation if not 408,429,503,504 errors
					// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
					// Display what the error is
					displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					
					// abort ..
					return;
				}
				
				// OneDrive Personal Shared Folder Check - Use the REAL online data here
				if (appConfig.accountType == "personal") {
					// We are a personal account, this existing online folder, it could be a Shared Online Folder could be a 'Add shortcut to My files' item
					// Is this a remote folder
					if (isItemRemote(realOnlinePathData)) {
						// The folder is a remote item ...
						if (debugLogging) {addLogEntry("The existing Online Folder and 'realOnlinePathData' indicate this is most likely a OneDrive Personal Shared Folder Link added by 'Add shortcut to My files'", ["debug"]);}
						// It is a 'remote' JSON item denoting a potential shared folder
						// Create a 'root' and 'Shared Folder' DB Tie Records for this JSON object in a consistent manner
						createRequiredSharedFolderDatabaseRecords(realOnlinePathData);
					}
				}
				
				// OneDrive Business Shared Folder Check
				if (appConfig.accountType == "business") {
					// We are a business account, this existing online folder, it could be a Shared Online Folder could be a 'Add shortcut to My files' item
					// Is this a remote folder
					if (isItemRemote(realOnlinePathData)) {
						// The folder is a remote item ... 
						if (debugLogging) {addLogEntry("The existing Online Folder and 'realOnlinePathData' indicate this is most likely a OneDrive Shared Business Folder Link added by 'Add shortcut to My files'", ["debug"]);}
						
						// Is Shared Business Folder Syncing actually enabled?
						if (!appConfig.getValueBool("sync_business_shared_items")) {
							// Shared Business Folder Syncing is NOT enabled
							if (debugLogging) {addLogEntry("We need to skip this path: " ~ thisNewPathToCreate, ["debug"]);}
							// Add this path to businessSharedFoldersOnlineToSkip
							businessSharedFoldersOnlineToSkip ~= [thisNewPathToCreate];
							// no save to database, no online create
							
							// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
							createDirectoryOnlineOneDriveApiInstance.releaseCurlEngine();
							createDirectoryOnlineOneDriveApiInstance = null;
							// Perform Garbage Collection
							GC.collect();
							
							// Display function processing time if configured to do so
							if (appConfig.getValueBool("display_processing_time") && debugLogging) {
								// Combine module name & running Function
								displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
							}
							
							// return due to skipped path
							return;
						} else {
							// Shared Business Folder Syncing IS enabled
							// It is a 'remote' JSON item denoting a potential shared folder
							// Create a 'root' and 'Shared Folder' DB Tie Records for this JSON object in a consistent manner
							createRequiredSharedFolderDatabaseRecords(realOnlinePathData);
						}
					}
				}
				
				// Path found online
				if (verboseLogging) {addLogEntry("The requested directory to create was found on OneDrive - skipping creating the directory online: " ~ thisNewPathToCreate, ["verbose"]);}
				// Is the response a valid JSON object - validation checking done in saveItem
				saveItem(realOnlinePathData);
				
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				createDirectoryOnlineOneDriveApiInstance.releaseCurlEngine();
				createDirectoryOnlineOneDriveApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
				
				// return due to path found online
				return;
			} else {
				// Normally this would throw an error, however we cant use throw new PosixException()
				string msg = format("POSIX 'case-insensitive match' between '%s' (local) and '%s' (online) which violates the Microsoft OneDrive API namespace convention", baseName(thisNewPathToCreate), onlinePathData["name"].str);
				displayPosixErrorMessage(msg);
				addLogEntry("ERROR: Requested directory to create has a 'case-insensitive match' to an existing directory on Microsoft OneDrive online.");
				addLogEntry("ERROR: To resolve, rename this local directory: " ~ buildNormalizedPath(absolutePath(thisNewPathToCreate)));
				addLogEntry("Skipping creating this directory online due to 'case-insensitive match': " ~ thisNewPathToCreate);
				// Add this path to posixViolationPaths
				posixViolationPaths ~= [thisNewPathToCreate];
				
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				createDirectoryOnlineOneDriveApiInstance.releaseCurlEngine();
				createDirectoryOnlineOneDriveApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
				
				// manual POSIX exception
				return;
			}
		} else {
			// response is not valid JSON, an error was returned from OneDrive
			addLogEntry("ERROR: There was an error performing this operation on Microsoft OneDrive");
			addLogEntry("ERROR: Increase logging verbosity to assist determining why.");
			addLogEntry("Skipping: " ~ buildNormalizedPath(absolutePath(thisNewPathToCreate)));
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			createDirectoryOnlineOneDriveApiInstance.releaseCurlEngine();
			createDirectoryOnlineOneDriveApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			
			// Display function processing time if configured to do so
			if (appConfig.getValueBool("display_processing_time") && debugLogging) {
				// Combine module name & running Function
				displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
			}
			
			// generic error
			return;
		}
	}
	
	// In the event that the online creation triggered a 404 then a 409 on creation attempt, this function explicitly is used to query that parent for the child being sought
	// This should return a usable JSON response of the folder being sought
	JSONValue resolveOnlineCreationRaceCondition(string requiredDriveId, string requiredParentItemId, string thisNewPathToCreate) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// Create a new API Instance for this thread and initialise it
		OneDriveApi raceConditionResolutionOneDriveApiInstance;
		raceConditionResolutionOneDriveApiInstance = new OneDriveApi(appConfig);
		raceConditionResolutionOneDriveApiInstance.initialise();
		
		// What is the folder we are seeking
		string searchFolder = baseName(thisNewPathToCreate);
		
		// Where should we store the details of the online folder we are seeking?
		JSONValue targetOnlineFolderDetails;
		
		// Required variables for listChildren to operate
		JSONValue topLevelChildren;
		string nextLink;
		bool directoryFoundOnline = false;
		
		// To handle ^c events, we need this Code
		while (true) {
			// Check if exitHandlerTriggered is true
			if (exitHandlerTriggered) {
				// break out of the 'while (true)' loop
				break;
			}
			
			// Query this remote object for its children
			topLevelChildren = raceConditionResolutionOneDriveApiInstance.listChildren(requiredDriveId, requiredParentItemId, nextLink);
			
			// Process each child that has been returned
			foreach (child; topLevelChildren["value"].array) {
				// We are specifically seeking a 'folder' object
				if (isItemFolder(child)) {
					// Is this the child folder we are looking for, and is a POSIX match?
					// We know that Microsoft OneDrive is not POSIX aware, thus there cannot be 2 folders of the same name with different case sensitivity
					if (child["name"].str == searchFolder) {
						// EXACT MATCH including case sensitivity: Flag that we found the folder online
						directoryFoundOnline = true;
						// Use these details for raceCondition response
						targetOnlineFolderDetails = child;
						break;
					} else {
						string childAsLower = toLower(child["name"].str);
						string thisFolderNameAsLower = toLower(searchFolder);
						
						try {
							if (childAsLower == thisFolderNameAsLower) {	
								// This is a POSIX 'case in-sensitive match' ..... 
								// Local item name has a 'case-insensitive match' to an existing item on OneDrive
								throw new PosixException(searchFolder, child["name"].str);
							}
						} catch (PosixException e) {
							// Display POSIX error message
							displayPosixErrorMessage(e.msg);
							addLogEntry("ERROR: Requested directory to search for and potentially create has a 'case-insensitive match' to an existing directory on Microsoft OneDrive online.");
							addLogEntry("ERROR: To resolve, rename this local directory: " ~ thisNewPathToCreate);
						}
					}
				}
			}
			
			// That set of returned objects - did we find the folder?
			if (directoryFoundOnline) {
				// We found the folder, no need to continue searching nextLink data
				break;
			}
			
			// If a collection exceeds the default page size (200 items), the @odata.nextLink property is returned in the response 
			// to indicate more items are available and provide the request URL for the next page of items.
			if ("@odata.nextLink" in topLevelChildren) {
				// Update nextLink to next changeSet bundle
				if (debugLogging) {addLogEntry("Setting nextLink to (@odata.nextLink): " ~ nextLink, ["debug"]);}
				nextLink = topLevelChildren["@odata.nextLink"].str;
			} else break;
			
			// Sleep for a while to avoid busy-waiting
			Thread.sleep(dur!"msecs"(100)); // Adjust the sleep duration as needed
		}
		
		// Shutdown this API instance, as we will create API instances as required, when required
		raceConditionResolutionOneDriveApiInstance.releaseCurlEngine();
		// Free object and memory
		raceConditionResolutionOneDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// Return the JSON with the folder details
		return targetOnlineFolderDetails;
	}
	
	// Test that the online name actually matches the requested local name
	bool performPosixTest(string localNameToCheck, string onlineName) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// https://docs.microsoft.com/en-us/windows/desktop/FileIO/naming-a-file
		// Do not assume case sensitivity. For example, consider the names OSCAR, Oscar, and oscar to be the same, 
		// even though some file systems (such as a POSIX-compliant file system) may consider them as different. 
		// Note that NTFS supports POSIX semantics for case sensitivity but this is not the default behavior.
		bool posixIssue = false;
		
		// Check for a POSIX casing mismatch
		if (localNameToCheck != onlineName) {
			// The input items are different .. how are they different?
			if (toLower(localNameToCheck) == toLower(onlineName)) {
				// Names differ only by case -> POSIX issue
				if (debugLogging) {addLogEntry("performPosixTest: Names differ only by case -> POSIX issue", ["debug"]);}
				// Local item name has a 'case-insensitive match' to an existing item on OneDrive
				posixIssue = true;
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// return the posix evaluation
		return posixIssue;
	}
	
	// Upload new file items as identified
	void uploadNewLocalFileItems() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}

		// Lets deal with the new local items in a batch process
		size_t batchSize = to!int(appConfig.getValueLong("threads"));
		long batchCount = (newLocalFilesToUploadToOneDrive.length + batchSize - 1) / batchSize;
		long batchesProcessed = 0;
		
		// Transfer order
		string transferOrder = appConfig.getValueString("transfer_order");
		
		// Has the user configured to specify the transfer order of files?
		if (transferOrder != "default") {
			// If we have more than 1 item to upload, sort the items
			if (count(newLocalFilesToUploadToOneDrive) > 1) {
				// Create an array of tuples (file path, file size)
				auto fileInfo = newLocalFilesToUploadToOneDrive
					.map!(file => tuple(file, getSize(file))) // Get file size for each file that needs to be uploaded
					.array;

				// Perform sorting based on transferOrder
				if (transferOrder == "size_asc") {
					fileInfo.sort!((a, b) => a[1] < b[1]); // sort the array by ascending size
				} else if (transferOrder == "size_dsc") {
					fileInfo.sort!((a, b) => a[1] > b[1]); // sort the array by descending size
				} else if (transferOrder == "name_asc") {
					fileInfo.sort!((a, b) => a[0] < b[0]); // sort the array by ascending name
				} else if (transferOrder == "name_dsc") {
					fileInfo.sort!((a, b) => a[0] > b[0]); // sort the array by descending name
				}
				
				// Extract sorted file paths
				newLocalFilesToUploadToOneDrive = fileInfo.map!(t => t[0]).array;
			}
		}
		
		// Process newLocalFilesToUploadToOneDrive
		foreach (chunk; newLocalFilesToUploadToOneDrive.chunks(batchSize)) {
			// send an array containing 'appConfig.getValueLong("threads")' local files to upload
			uploadNewLocalFileItemsInParallel(chunk);
		}
		
		// For this set of items, perform a DB PASSIVE checkpoint
		itemDB.performCheckpoint("PASSIVE");
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Upload the file batches in parallel
	void uploadNewLocalFileItemsInParallel(string[] array) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// This function received an array of string items to upload, the number of elements based on appConfig.getValueLong("threads")
		foreach (i, fileToUpload; processPool.parallel(array)) {
			if (debugLogging) {addLogEntry("Upload Thread " ~ to!string(i) ~ " Starting: " ~ to!string(Clock.currTime()), ["debug"]);}
			uploadNewFile(fileToUpload);
			if (debugLogging) {addLogEntry("Upload Thread " ~ to!string(i) ~ " Finished: " ~ to!string(Clock.currTime()), ["debug"]);}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Upload a new file to OneDrive
	void uploadNewFile(string fileToUpload) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Debug for the moment
		if (debugLogging) {addLogEntry("fileToUpload: " ~ fileToUpload, ["debug"]);}
		
		// These are the details of the item we need to upload
		// How much space is remaining on OneDrive
		long remainingFreeSpaceOnline;
		// Did the upload fail?
		bool uploadFailed = false;
		// Did we skip due to exceeding maximum allowed size?
		bool skippedMaxSize = false;
		// Did we skip to an exception error?
		bool skippedExceptionError = false;
		// Is the parent path in the item database?
		bool parentPathFoundInDB = false;
		// Get this file size
		long thisFileSize;
		// Is there space available online
		bool spaceAvailableOnline = false;
		
		DriveDetailsCache cachedOnlineDriveData;
		long calculatedSpaceOnlinePostUpload;
		
		OneDriveApi checkFileOneDriveApiInstance;
		
		// Check the database for the parent path of fileToUpload
		Item parentItem;
		// What parent path to use?
		string parentPath = dirName(fileToUpload); // will be either . or something else
		if (parentPath == "."){
			// Assume this is a new file in the users configured sync_dir root
			// Use client defaults
			parentItem.id = appConfig.defaultRootId;  		// Should give something like 12345ABCDE1234A1!101
			parentItem.driveId = appConfig.defaultDriveId; 	// Should give something like 12345abcde1234a1
			parentPathFoundInDB = true;
		} else {
			// Query the database using each of the driveId's we are using
			foreach (driveId; onlineDriveDetails.keys) {
				// Query the database for this parent path using each driveId
				Item dbResponse;
				if(itemDB.selectByPath(parentPath, driveId, dbResponse)){
					// parent path was found in the database
					parentItem = dbResponse;
					parentPathFoundInDB = true;
				}
			}
		}
		
		// If the parent path was found in the DB, to ensure we are uploading the right location 'parentItem.driveId' must not be empty
		if ((parentPathFoundInDB) && (parentItem.driveId.empty)) {
			// switch to using defaultDriveId
			if (debugLogging) {addLogEntry("parentItem.driveId is empty - using defaultDriveId for upload API calls", ["debug"]);}
			parentItem.driveId = appConfig.defaultDriveId;
		}
		
		// Check if the path still exists locally before we try to upload
		if (exists(fileToUpload)) {
			// Can we read the file - as a permissions issue or actual file corruption will cause a failure
			// Resolves: https://github.com/abraunegg/onedrive/issues/113
			if (readLocalFile(fileToUpload)) {
				// The local file can be read - so we can read it to attempt to upload it in this thread
				// Is the path parent in the DB?
				if (parentPathFoundInDB) {
					// Parent path is in the database
					// Get the new file size
					// Even if the permissions on the file are: -rw-------.  1 root root    8 Jan 11 09:42
					// we can still obtain the file size, however readLocalFile() also tests if the file can be read (permission check)
					thisFileSize = getSize(fileToUpload);
					
					// Does this file exceed the maximum filesize for OneDrive
					// Resolves: https://github.com/skilion/onedrive/issues/121 , https://github.com/skilion/onedrive/issues/294 , https://github.com/skilion/onedrive/issues/329
					if (thisFileSize <= maxUploadFileSize) {
						// Is there enough free space on OneDrive as compared to when we started this thread, to safely upload the file to OneDrive?
						
						// Make sure that parentItem.driveId is in our driveIDs array to use when checking if item is in database
						// Keep the DriveDetailsCache array with unique entries only
						if (!canFindDriveId(parentItem.driveId, cachedOnlineDriveData)) {
							// Add this driveId to the drive cache, which then also sets for the defaultDriveId:
							// - quotaRestricted;
							// - quotaAvailable;
							// - quotaRemaining;
							addOrUpdateOneDriveOnlineDetails(parentItem.driveId);
							// Fetch the details from cachedOnlineDriveData
							cachedOnlineDriveData = getDriveDetails(parentItem.driveId);
						} 
						
						// Fetch the details from cachedOnlineDriveData
						// - cachedOnlineDriveData.quotaRestricted;
						// - cachedOnlineDriveData.quotaAvailable;
						// - cachedOnlineDriveData.quotaRemaining;
						remainingFreeSpaceOnline = cachedOnlineDriveData.quotaRemaining;
						
						// When we compare the space online to the total we are trying to upload - is there space online?
						calculatedSpaceOnlinePostUpload = remainingFreeSpaceOnline - thisFileSize;
						
						// Based on what we know, for this thread - can we safely upload this modified local file?
						if (debugLogging) {
							string estimatedMessage = format("This Thread (Upload New File) Estimated Free Space Online (%s): ", parentItem.driveId);
							addLogEntry(estimatedMessage ~ to!string(remainingFreeSpaceOnline), ["debug"]);
							addLogEntry("This Thread (Upload New File) Calculated Free Space Online Post Upload: " ~ to!string(calculatedSpaceOnlinePostUpload), ["debug"]);
						}
			
						// If 'personal' accounts, if driveId == defaultDriveId, then we will have data - appConfig.quotaAvailable will be updated
						// If 'personal' accounts, if driveId != defaultDriveId, then we will not have quota data - appConfig.quotaRestricted will be set as true
						// If 'business' accounts, if driveId == defaultDriveId, then we will have data
						// If 'business' accounts, if driveId != defaultDriveId, then we will have data, but it will be a 0 value - appConfig.quotaRestricted will be set as true
						
						if (remainingFreeSpaceOnline > totalDataToUpload) {
							// Space available
							spaceAvailableOnline = true;
						} else {
							// we need to look more granular
							// What was the latest getRemainingFreeSpace() value?
							if (cachedOnlineDriveData.quotaAvailable) {
								// Our query told us we have free space online .. if we upload this file, will we exceed space online - thus upload will fail during upload?
								if (calculatedSpaceOnlinePostUpload > 0) {
									// Based on this thread action, we believe that there is space available online to upload - proceed
									spaceAvailableOnline = true;
								}
							}
						}
						
						// Is quota being restricted?
						if (cachedOnlineDriveData.quotaRestricted) {
							// Issue #3336 - Convert driveId to lowercase before any test
							if (appConfig.accountType == "personal") {
								parentItem.driveId = transformToLowerCase(parentItem.driveId);
							}
							
							// If the upload target drive is not our drive id, then it is a shared folder .. we need to print a space warning message
							if (parentItem.driveId != appConfig.defaultDriveId) {
								// Different message depending on account type
								if (appConfig.accountType == "personal") {
									if (verboseLogging) {addLogEntry("WARNING: Shared Folder OneDrive quota information is being restricted or providing a zero value. Space available online cannot be guaranteed.", ["verbose"]);}
								} else {
									if (verboseLogging) {addLogEntry("WARNING: Shared Folder OneDrive quota information is being restricted or providing a zero value. Please fix by speaking to your OneDrive / Office 365 Administrator.", ["verbose"]);}
								}
							} else {
								if (appConfig.accountType == "personal") {
									if (verboseLogging) {addLogEntry("WARNING: OneDrive quota information is being restricted or providing a zero value. Space available online cannot be guaranteed.", ["verbose"]);}
								} else {
									if (verboseLogging) {addLogEntry("WARNING: OneDrive quota information is being restricted or providing a zero value. Please fix by speaking to your OneDrive / Office 365 Administrator.", ["verbose"]);}
								}
							}
							// Space available online is being restricted - so we have no way to really know if there is space available online
							spaceAvailableOnline = true;
						}
						
						// Do we have space available or is space available being restricted (so we make the blind assumption that there is space available)
						if (spaceAvailableOnline) {
							// We need to check that this new local file does not exist on OneDrive
							JSONValue fileDetailsFromOneDrive;

							// https://docs.microsoft.com/en-us/windows/desktop/FileIO/naming-a-file
							// Do not assume case sensitivity. For example, consider the names OSCAR, Oscar, and oscar to be the same, 
							// even though some file systems (such as a POSIX-compliant file systems that Linux use) may consider them as different.
							// Note that NTFS supports POSIX semantics for case sensitivity but this is not the default behavior, OneDrive does not use this.
							
							// In order to upload this file - this query HAS to respond with a '404 - Not Found' so that the upload is triggered
							
							// Does this 'file' already exist on OneDrive?
							try {
							
								// Create a new API Instance for this thread and initialise it
								checkFileOneDriveApiInstance = new OneDriveApi(appConfig);
								checkFileOneDriveApiInstance.initialise();
								
								// Issue #3336 - Convert driveId to lowercase before any test
								if (appConfig.accountType == "personal") {
									parentItem.driveId = transformToLowerCase(parentItem.driveId);
								}

								if (parentItem.driveId == appConfig.defaultDriveId) {
									// getPathDetailsByDriveId is only reliable when the driveId is our driveId
									fileDetailsFromOneDrive = checkFileOneDriveApiInstance.getPathDetailsByDriveId(parentItem.driveId, fileToUpload);
								} else {
									// We need to curate a response by listing the children of this parentItem.driveId and parentItem.id , without traversing directories
									// So that IF the file is on a Shared Folder, it can be found, and, if it exists, checked correctly
									fileDetailsFromOneDrive = searchDriveItemForFile(parentItem.driveId, parentItem.id, fileToUpload);
									// Was the file found?
									if (fileDetailsFromOneDrive.type() != JSONType.object) {
										// No ....
										throw new OneDriveException(404, "Name not found via searchDriveItemForFile");
									}
								}
								
								// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
								checkFileOneDriveApiInstance.releaseCurlEngine();
								checkFileOneDriveApiInstance = null;
								// Perform Garbage Collection
								GC.collect();
								
								// No 404 which means a file was found with the path we are trying to upload to
								if (debugLogging) {addLogEntry("fileDetailsFromOneDrive JSON data after exist online check: " ~ to!string(fileDetailsFromOneDrive), ["debug"]);}
																
								// Portable Operating System Interface (POSIX) testing of JSON response from OneDrive API
								if (hasName(fileDetailsFromOneDrive)) {
									// Perform the POSIX evaluation test against the names
									if (performPosixTest(baseName(fileToUpload), fileDetailsFromOneDrive["name"].str)) {
										throw new PosixException(baseName(fileToUpload), fileDetailsFromOneDrive["name"].str);
									}
								} else {
									throw new JsonResponseException("Unable to perform POSIX test as the OneDrive API request generated an invalid JSON response");
								}
								
								// If we get to this point, the OneDrive API returned a 200 OK with valid JSON data that indicates a 'file' exists at this location already
								// and that it matches the POSIX filename of the local item we are trying to upload as a new file
								if (verboseLogging) {addLogEntry("The file we are attempting to upload as a new file already exists on Microsoft OneDrive: " ~ fileToUpload, ["verbose"]);}
								
								// Does the data from online match our local file that we are attempting to upload as a new file?
								if (!disableUploadValidation && performUploadIntegrityValidationChecks(fileDetailsFromOneDrive, fileToUpload, thisFileSize)) {
									// Save online item details to the database
									saveItem(fileDetailsFromOneDrive);
								} else {
									// The local file we are attempting to upload as a new file is different to the existing file online
									if (debugLogging) {addLogEntry("Triggering newfile upload target already exists edge case, where the online item does not match what we are trying to upload", ["debug"]);}
									
									// Issue #2626 | Case 2-2 (resync)
									
									// If the 'online' file is newer, this will be overwritten with the file from the local filesystem - potentially constituting online data loss
									// The file 'version history' online will have to be used to 'recover' the prior online file
									string changedItemParentDriveId = fileDetailsFromOneDrive["parentReference"]["driveId"].str;
									string changedItemId = fileDetailsFromOneDrive["id"].str;
									addLogEntry("Skipping uploading this item as a new file, will upload as a modified file (online file already exists): " ~ fileToUpload);
									
									// In order for the processing of the local item as a 'changed' item, unfortunately we need to save the online data of the existing online file to the local DB
									saveItem(fileDetailsFromOneDrive);
									
									// Which file is technically newer? The local file or the remote file?
									Item onlineFile = makeItem(fileDetailsFromOneDrive);
									SysTime localModifiedTime = timeLastModified(fileToUpload).toUTC();
									SysTime onlineModifiedTime = onlineFile.mtime;
									
									// Reduce time resolution to seconds before comparing
									localModifiedTime.fracSecs = Duration.zero;
									onlineModifiedTime.fracSecs = Duration.zero;
									
									// Which file is newer?
									if (localModifiedTime >= onlineModifiedTime) {
										// Upload the locally modified file as-is, as it is newer
										uploadChangedLocalFileToOneDrive([changedItemParentDriveId, changedItemId, fileToUpload]);
									} else {
										// Online is newer, rename local, then upload the renamed file
										// We need to know the renamed path so we can upload it
										string renamedPath;
										// Rename the local path - we WANT this to occur regardless of bypassDataPreservation setting
										safeBackup(fileToUpload, dryRun, false, renamedPath);
										// Upload renamed local file as a new file
										uploadNewFile(renamedPath);
										// Process the database entry removal for the original file. In a --dry-run scenario, this is being done against a DB copy.
										// This is done so we can download the newer online file
										itemDB.deleteById(changedItemParentDriveId, changedItemId);
									}
								}
							} catch (OneDriveException exception) {
								// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
								checkFileOneDriveApiInstance.releaseCurlEngine();
								checkFileOneDriveApiInstance = null;
								// Perform Garbage Collection
								GC.collect();
								
								// If we get a 404 .. the file is not online .. this is what we want .. file does not exist online
								if (exception.httpStatusCode == 404) {
									// The file has been checked, client side filtering checked, does not exist online - we need to upload it
									if (debugLogging) {addLogEntry("fileDetailsFromOneDrive = checkFileOneDriveApiInstance.getPathDetailsByDriveId(parentItem.driveId, fileToUpload); generated a 404 - file does not exist online - must upload it", ["debug"]);}
									uploadFailed = performNewFileUpload(parentItem, fileToUpload, thisFileSize);
								} else {
									// some other error
									// Default operation if not 408,429,503,504 errors
									// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
									// Display what the error is
									displayOneDriveErrorMessage(exception.msg, thisFunctionName);
								}
							} catch (PosixException e) {
								// Display POSIX error message
								displayPosixErrorMessage(e.msg);
								addLogEntry("ERROR: Requested file to upload has a 'case-insensitive match' to an existing item on Microsoft OneDrive online.");
								addLogEntry("ERROR: To resolve, rename this local file: " ~ fileToUpload);
								addLogEntry("Skipping uploading this new file due to 'case-insensitive match': " ~ fileToUpload);
								uploadFailed = true;
							} catch (JsonResponseException e) {
								// Display JSON error message
								if (debugLogging) {addLogEntry(e.msg, ["debug"]);}
								uploadFailed = true;
							}
						} else {
							// skip file upload - insufficient space to upload
							addLogEntry("Skipping uploading this new file as it exceeds the available free space on Microsoft OneDrive: " ~ fileToUpload);
							uploadFailed = true;
						}
					} else {
						// Skip file upload - too large
						addLogEntry("Skipping uploading this new file as it exceeds the maximum size allowed by Microsoft OneDrive: " ~ fileToUpload);
						uploadFailed = true;
					}
				} else {
					// why was the parent path not in the database?
					if (canFind(posixViolationPaths, parentPath)) {
						addLogEntry("ERROR: POSIX 'case-insensitive match' for the parent path which violates the Microsoft OneDrive API namespace convention.");
					} else {
						addLogEntry("ERROR: Parent path is not in the database or online: " ~ parentPath);
					}
					addLogEntry("ERROR: Unable to upload this file: " ~ fileToUpload);
					uploadFailed = true;
				}
			} else {
				// Unable to read local file
				addLogEntry("Skipping uploading this file as it cannot be read (file permissions or file corruption): " ~ fileToUpload);
				uploadFailed = true;
			}
		} else {
			// File disappeared before upload
			addLogEntry("File disappeared locally before upload: " ~ fileToUpload);
			// dont set uploadFailed = true; as the file disappeared before upload, thus nothing here failed
		}

		// Upload success or failure?
		if (!uploadFailed) {
			// Update the 'cachedOnlineDriveData' record for this 'dbItem.driveId' so that this is tracked as accurately as possible for other threads
			updateDriveDetailsCache(parentItem.driveId, cachedOnlineDriveData.quotaRestricted, cachedOnlineDriveData.quotaAvailable, thisFileSize);
		} else {
			// Need to add this to fileUploadFailures to capture at the end
			fileUploadFailures ~= fileToUpload;
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
		
	// Perform the actual upload to OneDrive
	bool performNewFileUpload(Item parentItem, string fileToUpload, long thisFileSize) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
			
		// Assume that by default the upload fails
		bool uploadFailed = true;
		
		// OneDrive API Upload Response
		JSONValue uploadResponse;
		
		// Create the OneDriveAPI Upload Instance
		OneDriveApi uploadFileOneDriveApiInstance;
		
		// Capture what time this upload started
		SysTime uploadStartTime = Clock.currTime();
		
		// Is this a dry-run scenario?
		if (!dryRun) {
			// Not a dry-run situation
			// Do we use simpleUpload or create an upload session?
			bool useSimpleUpload = false;
			
			// What upload method should be used?
			if (thisFileSize <= sessionThresholdFileSize) {
				useSimpleUpload = true;
			}
			
			// Use Session Upload regardless
			if (appConfig.getValueBool("force_session_upload")) {
				// Forcing session upload
				if (debugLogging) {addLogEntry("Forcing to perform upload using a session (newfile)", ["debug"]);}
				useSimpleUpload = false;
			}
			
			// We can only upload zero size files via simpleFileUpload regardless of account type
			// Reference: https://github.com/OneDrive/onedrive-api-docs/issues/53
			// Additionally, only where file size is < 4MB should be uploaded by simpleUpload - everything else should use a session to upload
			
			if ((thisFileSize == 0) || (useSimpleUpload)) { 
				try {
					// Initialise API for simple upload
					uploadFileOneDriveApiInstance = new OneDriveApi(appConfig);
					uploadFileOneDriveApiInstance.initialise();
				
					// Attempt to upload the zero byte file using simpleUpload for all account types
					uploadResponse = uploadFileOneDriveApiInstance.simpleUpload(fileToUpload, parentItem.driveId, parentItem.id, baseName(fileToUpload));
					uploadFailed = false;
					addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... done", fileTransferNotifications());
					
					// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
					uploadFileOneDriveApiInstance.releaseCurlEngine();
					uploadFileOneDriveApiInstance = null;
					// Perform Garbage Collection
					GC.collect();
					
				} catch (OneDriveException exception) {
					// An error was responded with - what was it
					// Default operation if not 408,429,503,504 errors
					// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
					// Display what the error is
					addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... failed!", ["info", "notify"]);
					displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					
					// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
					uploadFileOneDriveApiInstance.releaseCurlEngine();
					uploadFileOneDriveApiInstance = null;
					// Perform Garbage Collection
					GC.collect();
					
				} catch (FileException e) {
					// display the error message
					addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... failed!", ["info", "notify"]);
					displayFileSystemErrorMessage(e.msg, thisFunctionName);
					
					// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
					uploadFileOneDriveApiInstance.releaseCurlEngine();
					uploadFileOneDriveApiInstance = null;
					// Perform Garbage Collection
					GC.collect();
				}
			} else {
				// Initialise API for session upload
				uploadFileOneDriveApiInstance = new OneDriveApi(appConfig);
				uploadFileOneDriveApiInstance.initialise();
				
				// Session Upload for this criteria:
				// - Personal Account and file size > 4MB
				// - All Business | Office365 | SharePoint files > 0 bytes
				JSONValue uploadSessionData;
				// As this is a unique thread, the sessionFilePath for where we save the data needs to be unique
				// The best way to do this is generate a 10 digit alphanumeric string, and use this as the file extension
				string threadUploadSessionFilePath = appConfig.uploadSessionFilePath ~ "." ~ generateAlphanumericString();
				
				// Attempt to upload the > 4MB file using an upload session for all account types
				try {
					// Create the Upload Session
					uploadSessionData = createSessionForFileUpload(uploadFileOneDriveApiInstance, fileToUpload, parentItem.driveId, parentItem.id, baseName(fileToUpload), null, threadUploadSessionFilePath);
				} catch (OneDriveException exception) {
					// An error was responded with - what was it
					// Default operation if not 408,429,503,504 errors
					// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
					// Display what the error is
					addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... failed!", ["info", "notify"]);
					displayOneDriveErrorMessage(exception.msg, thisFunctionName);
										
				} catch (FileException e) {
					// display the error message
					addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... failed!", ["info", "notify"]);
					displayFileSystemErrorMessage(e.msg, thisFunctionName);
				}
				
				// Do we have a valid session URL that we can use ?
				if (uploadSessionData.type() == JSONType.object) {
					// This is a valid JSON object
					bool sessionDataValid = true;
					
					// Validate that we have the following items which we need
					if (!hasUploadURL(uploadSessionData)) {
						sessionDataValid = false;
						if (debugLogging) {addLogEntry("Session data missing 'uploadUrl'", ["debug"]);}
					}
					
					if (!hasNextExpectedRanges(uploadSessionData)) {
						sessionDataValid = false;
						if (debugLogging) {addLogEntry("Session data missing 'nextExpectedRanges'", ["debug"]);}
					}
					
					if (!hasLocalPath(uploadSessionData)) {
						sessionDataValid = false;
						if (debugLogging) {addLogEntry("Session data missing 'localPath'", ["debug"]);}
					}
								
					if (sessionDataValid) {
						// We have a valid Upload Session Data we can use
						try {
							// Try and perform the upload session
							uploadResponse = performSessionFileUpload(uploadFileOneDriveApiInstance, thisFileSize, uploadSessionData, threadUploadSessionFilePath);
							
							if (uploadResponse.type() == JSONType.object) {
								uploadFailed = false;
								addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... done", fileTransferNotifications());
							} else {
								addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... failed!", ["info", "notify"]);
								uploadFailed = true;
							}
						} catch (OneDriveException exception) {
							// Default operation if not 408,429,503,504 errors
							// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
							// Display what the error is
							addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... failed!", ["info", "notify"]);
							displayOneDriveErrorMessage(exception.msg, thisFunctionName);
							
						}
					} else {
						// No Upload URL or nextExpectedRanges or localPath .. not a valid JSON we can use
						if (verboseLogging) {addLogEntry("Session data is missing required elements to perform a session upload.", ["verbose"]);}
						addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... failed!", ["info", "notify"]);
					}
				} else {
					// Create session Upload URL failed
					addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... failed!", ["info", "notify"]);
				}
				
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				uploadFileOneDriveApiInstance.releaseCurlEngine();
				uploadFileOneDriveApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
			}
		} else {
			// We are in a --dry-run scenario
			uploadResponse = createFakeResponse(fileToUpload);
			uploadFailed = false;
			addLogEntry("Uploading new file: " ~ fileToUpload ~ " ... done", fileTransferNotifications());
		}
		
		// If no upload failure, calculate transfer metrics, perform integrity validation
		if (!uploadFailed) {
			// Upload did not fail ...
			// As no upload failure, calculate transfer metrics in a consistent manner
			displayTransferMetrics(fileToUpload, thisFileSize, uploadStartTime, Clock.currTime());
			
			// OK as the upload did not fail, we need to save the response from OneDrive, but it has to be a valid JSON response
			if (uploadResponse.type() == JSONType.object) {
				// check if the path still exists locally before we try to set the file times online - as short lived files, whilst we uploaded it - it may not exist locally already
				if (exists(fileToUpload)) {
					// Are we in a --dry-run scenario
					if (!dryRun) {
						bool uploadIntegrityPassed;
						// Check the integrity of the uploaded file, if the local file still exists
						uploadIntegrityPassed = performUploadIntegrityValidationChecks(uploadResponse, fileToUpload, thisFileSize);
						
						// Update the file modified time on OneDrive and save item details to database
						// Update the item's metadata on OneDrive
						SysTime mtime = timeLastModified(fileToUpload).toUTC();
						mtime.fracSecs = Duration.zero;
						string newFileId = uploadResponse["id"].str;
						string newFileETag = uploadResponse["eTag"].str;
						// Attempt to update the online date time stamp based on our local data
						if (appConfig.accountType == "personal") {
							// Business | SharePoint we used a session to upload the data, thus, local timestamps are given when the session is created
							uploadLastModifiedTime(parentItem, parentItem.driveId, newFileId, mtime, newFileETag);
						} else {
							// Due to https://github.com/OneDrive/onedrive-api-docs/issues/935 Microsoft modifies all PDF, MS Office & HTML files with added XML content. It is a 'feature' of SharePoint.
							// This means that the file which was uploaded, is potentially no longer the file we have locally
							// There are 2 ways to solve this:
							//   1. Download the modified file immediately after upload as per v2.4.x (default)
							//   2. Create a new online version of the file, which then contributes to the users 'quota'
							if (!uploadIntegrityPassed) {
								// upload integrity check failed
								// We do not want to create a new online file version .. unless configured to do so
								if (!appConfig.getValueBool("create_new_file_version")) {
									// are we in an --upload-only scenario
									if(!uploadOnly){
										// Download the now online modified file
										addLogEntry("WARNING: Microsoft OneDrive modified your uploaded file via its SharePoint 'enrichment' feature. To keep your local and online versions consistent, the altered file will now be downloaded.");
										addLogEntry("WARNING: Please refer to https://github.com/OneDrive/onedrive-api-docs/issues/935 for further details.");
										// Download the file directly using the prior upload JSON response
										downloadFileItem(uploadResponse, true);
									} else {
										// --upload-only being used
										// we are not downloading a file, warn that file differences will exist
										addLogEntry("WARNING: The file uploaded to Microsoft OneDrive has been modified through its SharePoint 'enrichment' process and no longer matches your local version.");
										addLogEntry("WARNING: The online metadata will now be modified to match your local file which will create a new file version.");
										addLogEntry("WARNING: Please refer to https://github.com/OneDrive/onedrive-api-docs/issues/935 for further details.");
										// Create a new online version of the file by updating the metadata - this ensures that the file we uploaded is the file online
										uploadLastModifiedTime(parentItem, parentItem.driveId, newFileId, mtime, newFileETag);
									}
								} else {
									// Create a new online version of the file by updating the metadata, which negates the need to download the file
									uploadLastModifiedTime(parentItem, parentItem.driveId, newFileId, mtime, newFileETag);
								}
							} else {
								// integrity checks passed
								// save the uploadResponse to the database
								saveItem(uploadResponse);
							}
						}
					}
					
					// Are we in an --upload-only & --remove-source-files scenario?
					// Use actual config values as we are doing an upload session recovery
					if ((uploadOnly) && (localDeleteAfterUpload)) {
						// Perform the local file deletion
						removeLocalFilePostUpload(fileToUpload);
					}
				} else {
					// will be removed in different event!
					addLogEntry("File disappeared locally after upload: " ~ fileToUpload);
				}
			} else {
				// Log that an invalid JSON object was returned
				if (debugLogging) {addLogEntry("uploadFileOneDriveApiInstance.simpleUpload or session.upload call returned an invalid JSON Object from the OneDrive API", ["debug"]);}
			}
		}

		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// Return upload status
		return uploadFailed;
	}
	
	// Create the OneDrive Upload Session
	JSONValue createSessionForFileUpload(OneDriveApi activeOneDriveApiInstance, string fileToUpload, string parentDriveId, string parentId, string filename, string eTag, string threadUploadSessionFilePath) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Upload file via a OneDrive API session
		JSONValue uploadSession;
		
		// Calculate modification time
		SysTime localFileLastModifiedTime = timeLastModified(fileToUpload).toUTC();
		localFileLastModifiedTime.fracSecs = Duration.zero;
		
		// Construct the fileSystemInfo JSON component needed to create the Upload Session
		JSONValue fileSystemInfo = [
				"item": JSONValue([
					"@microsoft.graph.conflictBehavior": JSONValue("replace"),
					"fileSystemInfo": JSONValue([
						"lastModifiedDateTime": localFileLastModifiedTime.toISOExtString()
					])
				])
			];
		
		// Try to create the upload session for this file
		uploadSession = activeOneDriveApiInstance.createUploadSession(parentDriveId, parentId, filename, eTag, fileSystemInfo);
		
		if (uploadSession.type() == JSONType.object) {
			// a valid session object was created
			if ("uploadUrl" in uploadSession) {
				// Add the file path we are uploading to this JSON Session Data
				uploadSession["localPath"] = fileToUpload;
				// Save this session
				saveSessionFile(threadUploadSessionFilePath, uploadSession);
			}
			
			// When does this upload URL expire?
			displayUploadSessionExpiry(uploadSession);
		} else {
			// no valid session was created
			if (verboseLogging) {addLogEntry("Creation of OneDrive API Upload Session failed.", ["verbose"]);}
			// return upload() will return a JSONValue response, create an empty JSONValue response to return
			uploadSession = null;
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// Return the JSON
		return uploadSession;
	}
	
	// Display upload session expiry time
	void displayUploadSessionExpiry(JSONValue uploadSessionData) {
		try {
			// Step 1: Extract the ISO 8601 UTC string from the JSON
			string utcExpiry = uploadSessionData["expirationDateTime"].str;

			// Step 2: Convert ISO 8601 string to SysTime (assumes Zulu / UTC timezone)
			SysTime expiryUTC = SysTime.fromISOExtString(utcExpiry);

			// Step 3: Convert to local time
			auto expiryLocal = expiryUTC.toLocalTime();

			// Step 4: Print both UTC and Local times
			if (debugLogging) {
				addLogEntry("Upload session URL expires at (UTC):   " ~ to!string(expiryUTC), ["debug"]);
				addLogEntry("Upload session URL expires at (Local): " ~ to!string(expiryLocal), ["debug"]);
			}
		} catch (Exception e) {
			// nothing
		}
	}
	
	// Save the session upload data
	void saveSessionFile(string threadUploadSessionFilePath, JSONValue uploadSessionData) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		try {
			std.file.write(threadUploadSessionFilePath, uploadSessionData.toString());
		} catch (FileException e) {
			// display the error message
			displayFileSystemErrorMessage(e.msg, thisFunctionName);
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Perform the upload of file via the Upload Session that was created
	JSONValue performSessionFileUpload(OneDriveApi activeOneDriveApiInstance, long thisFileSize, JSONValue uploadSessionData, string threadUploadSessionFilePath) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
			
		// Response for upload
		JSONValue uploadResponse;

		// https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0#upload-bytes-to-the-upload-session
		// You can upload the entire file, or split the file into multiple byte ranges, as long as the maximum bytes in any given request is less than 60 MiB.
		// Calculate File Fragment Size (must be valid multiple of 320 KiB)
		long baseSize;
		long fragmentSize;
		enum CHUNK_SIZE = 327_680L; // 320 KiB
		enum MAX_FRAGMENT_BYTES = 60L * 1_048_576L; // 60 MiB = 62,914,560 bytes
		
		// Time sensitive and ETA string items
		SysTime currentTime = Clock.currTime();
		long start_unix_time = currentTime.toUnixTime();
		int h, m, s;
		string etaString;
		
		// Upload string template
		string uploadLogEntry = "Uploading: " ~ uploadSessionData["localPath"].str ~ " ... ";
		
		// Calculate base size using configured fragment size
		baseSize = appConfig.getValueLong("file_fragment_size") * 2^^20;
				
		// Ensure 'fragmentSize' is a multiple of 327680 bytes and < 60 MiB
		if (baseSize >= MAX_FRAGMENT_BYTES) {
			// Use the maximum valid size below 60 MiB, rounded down to nearest 320 KiB multiple
			fragmentSize = ((MAX_FRAGMENT_BYTES - 1) / CHUNK_SIZE) * CHUNK_SIZE;
		} else {
			fragmentSize = (baseSize / CHUNK_SIZE) * CHUNK_SIZE;
		}
		
		// Set the fragment count and fragSize
		size_t fragmentCount = 0;
		long fragSize = 0;
		
		// Extract current upload offset from session data
		long offset = uploadSessionData["nextExpectedRanges"][0].str.splitter('-').front.to!long;
		
		// Estimate total number of expected fragments
		size_t expected_total_fragments = cast(size_t) ceil(double(thisFileSize) / double(fragmentSize));
		
		// If we get a 404, create a new upload session and store it here
		JSONValue newUploadSession;
		
		// Start the session upload using the active API instance for this thread
		while (true) {
			// fragment upload
			fragmentCount++;
			if (debugLogging) {addLogEntry("Fragment: " ~ to!string(fragmentCount) ~ " of " ~ to!string(expected_total_fragments), ["debug"]);}

			// Generate ETA time output
			etaString = formatETA(calc_eta((fragmentCount -1), expected_total_fragments, start_unix_time));
			
			// Calculate this progress output
			auto ratio = cast(double)(fragmentCount - 1) / expected_total_fragments;
			// Convert the ratio to a percentage and format it to two decimal places
			string percentage = leftJustify(format("%d%%", cast(int)(ratio * 100)), 5, ' ');
			addLogEntry(uploadLogEntry ~ percentage ~ etaString, ["consoleOnly"]);

			// What fragment size will be used?
			if (debugLogging) {addLogEntry("fragmentSize: " ~ to!string(fragmentSize) ~ " offset: " ~ to!string(offset) ~ " thisFileSize: " ~ to!string(thisFileSize), ["debug"]);}

			fragSize = fragmentSize < thisFileSize - offset ? fragmentSize : thisFileSize - offset;
			if (debugLogging) {addLogEntry("Using fragSize: " ~ to!string(fragSize), ["debug"]);}

			// fragSize must not be a negative value
			if (fragSize < 0) {
				// Session upload will fail
				// not a JSON object - fragment upload failed
				if (verboseLogging) {addLogEntry("File upload session failed - invalid calculation of fragment size", ["verbose"]);}

				if (exists(threadUploadSessionFilePath)) {
					remove(threadUploadSessionFilePath);
				}
				// set uploadResponse to null as error
				uploadResponse = null;
				return uploadResponse;
			}

			// If the resume upload fails, we need to check for a return code here
			try {
				uploadResponse = activeOneDriveApiInstance.uploadFragment(
					uploadSessionData["uploadUrl"].str,
					uploadSessionData["localPath"].str,
					offset,
					fragSize,
					thisFileSize
				);
			} catch (OneDriveException exception) {
				// if a 100 uploadResponse is generated, continue
				if (exception.httpStatusCode == 100) {
					continue;
				}
				
				// Issue #3355: https://github.com/abraunegg/onedrive/issues/3355
				if (exception.httpStatusCode == 403 && (exception.msg.canFind("accessDenied") || exception.msg.canFind("You do not have authorization to access the file"))) {
					addLogEntry("ERROR: Upload session has expired (403 - Access Denied)");
					addLogEntry("Probable Cause: The 'tempauth' token embedded in the upload URL has most likely expired.");
					addLogEntry("                Microsoft issues this token when the upload session is first created. It cannot be refreshed, extended, or queried for its expiry time.");
					addLogEntry("                The only way to infer its validity is by measuring the time from session creation to this 403 failure.");
					addLogEntry("                The upload session URL itself may still appear active (based on expirationDateTime), but the upload URL is no longer usable once this 'tempauth' token expires.");
					addLogEntry("                A new upload session will now be created. Upload will restart from the beginning using the new session URL and new 'tempauth' token.");
					
					// Attempt creation of new upload session
					newUploadSession = createSessionForFileUpload(
						activeOneDriveApiInstance,
						uploadSessionData["localPath"].str,
						uploadSessionData["targetDriveId"].str,
						uploadSessionData["targetParentId"].str,
						baseName(uploadSessionData["localPath"].str),
						null,
						threadUploadSessionFilePath
					);
					
					// Attempt retry (which will start upload again from scratch) with new session upload URL
					continue;
				}
				
				// There was an error uploadResponse from OneDrive when uploading the file fragment
				if (exception.httpStatusCode == 404) {
					// The upload session was not found .. ?? we just created it .. maybe the backend is still creating it or failed to create it
					if (debugLogging) {addLogEntry("The upload session was not found .... re-create session");}
					newUploadSession = createSessionForFileUpload(
						activeOneDriveApiInstance, 
						uploadSessionData["localPath"].str, 
						uploadSessionData["targetDriveId"].str, 
						uploadSessionData["targetParentId"].str, 
						baseName(uploadSessionData["localPath"].str), 
						null, 
						threadUploadSessionFilePath
					);
				}

				// Issue https://github.com/abraunegg/onedrive/issues/2747
				// if a 416 uploadResponse is generated, continue
				if (exception.httpStatusCode == 416) {
					continue;
				}

				// Handle transient errors:
				//   408 - Request Time Out
				//   429 - Too Many Requests
				//   503 - Service Unavailable
				//   504 - Gateway Timeout

				// Insert a new line as well, so that the below error is inserted on the console in the right location
				if (verboseLogging) {addLogEntry("Fragment upload failed - received an exception response from OneDrive API", ["verbose"]);}

				// display what the error is if we have not already continued
				if (exception.httpStatusCode != 404) {
					displayOneDriveErrorMessage(exception.msg, thisFunctionName);
				}

				// retry fragment upload in case error is transient
				if (verboseLogging) {addLogEntry("Retrying fragment upload", ["verbose"]);}

				// Retry fragment upload logic
				try {
					string effectiveRetryUploadURL;
					string effectiveLocalPath;

					// If we re-created the session, use the new data on re-try
					if (newUploadSession.type() == JSONType.object) {
						if ("uploadUrl" in newUploadSession) {
							// get this from 'newUploadSession'
							effectiveRetryUploadURL = newUploadSession["uploadUrl"].str;
							effectiveLocalPath = newUploadSession["localPath"].str;
						} else {
							// get this from the original input
							effectiveRetryUploadURL = uploadSessionData["uploadUrl"].str;
							effectiveLocalPath = uploadSessionData["localPath"].str;
						}

						// retry the fragment upload
						uploadResponse = activeOneDriveApiInstance.uploadFragment(
							effectiveRetryUploadURL,
							effectiveLocalPath,
							offset,
							fragSize,
							thisFileSize
						);
					} else {
						// newUploadSession not a JSON
						uploadResponse = null;
						return uploadResponse;
					}
				} catch (OneDriveException e) {
					// OneDrive threw another error on retry
					if (verboseLogging) {addLogEntry("Retry to upload fragment failed", ["verbose"]);}
					// display what the error is
					displayOneDriveErrorMessage(e.msg, thisFunctionName);
					// set uploadResponse to null as the fragment upload was in error twice
					uploadResponse = null;
					
				} catch (std.exception.ErrnoException e) {
					// There was a file system error - display the error message
					displayFileSystemErrorMessage(e.msg, thisFunctionName);
					return uploadResponse;
				}
			} catch (ErrnoException e) {
				// There was a file system error
				// display the error message
				displayFileSystemErrorMessage(e.msg, thisFunctionName);
				uploadResponse = null;
				return uploadResponse;
			}

			// was the fragment uploaded without issue?
			if (uploadResponse.type() == JSONType.object) {
				// Fragment uploaded
				if (debugLogging) {addLogEntry("Fragment upload complete", ["debug"]);}
				
				// Use updated offset from response, not fixed increment
				if ("nextExpectedRanges" in uploadResponse &&
					uploadResponse["nextExpectedRanges"].type() == JSONType.array &&
					!uploadResponse["nextExpectedRanges"].array.empty) {
					offset = uploadResponse["nextExpectedRanges"].array[0].str.splitter('-').front.to!long;
				} else {
					// No nextExpectedRanges? Assume upload complete
					break;
				}

				// update the uploadSessionData details
				uploadSessionData["expirationDateTime"] = uploadResponse["expirationDateTime"];
				uploadSessionData["nextExpectedRanges"] = uploadResponse["nextExpectedRanges"];
				
				// Log URL 'updated' expirationDateTime as 'UTC' and 'localTime'
				if (debugLogging) {
					// Convert expiration time to localTime
					string utcExpiry = uploadResponse["expirationDateTime"].str;
					SysTime expiryUTC = SysTime.fromISOExtString(utcExpiry);
					SysTime expiryLocal = expiryUTC.toLocalTime();
				
					// Display updated URL expiry as UTC and localTime
					addLogEntry("Upload Session URL expiration extended to (UTC):   " ~ to!string(expiryUTC), ["debug"]);
					addLogEntry("Upload Session URL expiration extended to (Local): " ~ to!string(expiryLocal), ["debug"]);
					addLogEntry("", ["debug"]); // Add new line as this fragment is complete
				}
				
				// Save for reuse
				saveSessionFile(threadUploadSessionFilePath, uploadSessionData);
			} else {
				// not a JSON object - fragment upload failed
				if (verboseLogging) {addLogEntry("File upload session failed - invalid response from OneDrive API", ["verbose"]);}

				// cleanup session data
				if (exists(threadUploadSessionFilePath)) {
					remove(threadUploadSessionFilePath);
				}
				// set uploadResponse to null as error
				uploadResponse = null;
				return uploadResponse;
			}
		}

		// Upload complete
		long end_unix_time = Clock.currTime.toUnixTime();
		auto upload_duration = cast(int)(end_unix_time - start_unix_time);
		dur!"seconds"(upload_duration).split!("hours", "minutes", "seconds")(h, m, s);
		etaString = format!"| DONE in %02d:%02d:%02d"(h, m, s);
		addLogEntry(uploadLogEntry ~ "100% " ~ etaString, ["consoleOnly"]);

		// Remove session file if it exists		
		if (exists(threadUploadSessionFilePath)) {
			remove(threadUploadSessionFilePath);
		}

		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}

		// Return the session upload response
		return uploadResponse;
	}

	
	// Delete an item on OneDrive
	void uploadDeletedItem(Item itemToDelete, string path) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		OneDriveApi uploadDeletedItemOneDriveApiInstance;
			
		// Are we in a situation where we HAVE to keep the data online - do not delete the remote object
		if (noRemoteDelete) {
			if ((itemToDelete.type == ItemType.dir)) {
				// Do not process remote directory delete
				if (verboseLogging) {addLogEntry("Skipping remote directory delete as --upload-only & --no-remote-delete configured", ["verbose"]);}
			} else {
				// Do not process remote file delete
				if (verboseLogging) {addLogEntry("Skipping remote file delete as --upload-only & --no-remote-delete configured", ["verbose"]);}
			}
		} else {
			
			// Is this a --download-only operation?
			if (!appConfig.getValueBool("download_only")) {
				// Process the delete - delete the object online
				addLogEntry("Deleting item from Microsoft OneDrive: " ~ path, fileTransferNotifications());
				bool flagAsBigDelete = false;
				
				Item[] children;
				long itemsToDelete;
			
				if ((itemToDelete.type == ItemType.dir)) {
					// Query the database - how many objects will this remove?
					children = getChildren(itemToDelete.driveId, itemToDelete.id);
					// Count the returned items + the original item (1)
					itemsToDelete = count(children) + 1;
					if (debugLogging) {addLogEntry("Number of items online to delete: " ~ to!string(itemsToDelete), ["debug"]);}
				} else {
					itemsToDelete = 1;
				}
				// Clear array
				children = [];
				
				// A local delete of a file|folder when using --monitor  will issue a inotify event, which will trigger the local & remote data immediately be deleted
				// The user may also be --sync process, so we are checking if something was deleted between application use
				if (itemsToDelete >= appConfig.getValueLong("classify_as_big_delete")) {
					// A big delete has been detected
					flagAsBigDelete = true;
					if (!appConfig.getValueBool("force")) {
						// Send this message to the GUI
						addLogEntry("ERROR: An attempt to remove a large volume of data from OneDrive has been detected. Exiting client to preserve your data on Microsoft OneDrive", ["info", "notify"]);
						
						// Additional application logging
						addLogEntry("ERROR: The total number of items being deleted is: " ~ to!string(itemsToDelete));
						addLogEntry("ERROR: To delete a large volume of data use --force or increase the config value 'classify_as_big_delete' to a larger value");
						
						// Must exit here to preserve data on online , allow logging to be done
						forceExit();
					}
				}
				
				// Are we in a --dry-run scenario?
				if (!dryRun) {
					// We are not in a dry run scenario
					if (debugLogging) {
						addLogEntry("itemToDelete: " ~ to!string(itemToDelete), ["debug"]);
						// what item are we trying to delete?
						addLogEntry("Attempting to delete this single item id: " ~ itemToDelete.id ~ " from drive: " ~ itemToDelete.driveId, ["debug"]);
					}
					
					// Configure these item variables to handle OneDrive Business Shared Folder Deletion
					Item actualItemToDelete;
					Item remoteShortcutLinkItem;
					
					// OneDrive Shared Folder Link Handling
					// - If the item to delete is on a remote drive ... technically we do not own this and should not be deleting this online
					//   We should however be deleting the 'link' in our account online, and, remove the DB link entries (root / folder DB Tie records)
					bool businessSharingEnabled = false;
					
					// OneDrive Business Shared Folder Deletion Handling
					// Is this a Business Account with Sync Business Shared Items enabled?
					if ((appConfig.accountType == "business") && (appConfig.getValueBool("sync_business_shared_items"))) {
						// Syncing Business Shared Items is enabled
						businessSharingEnabled = true;
					}
					
					// Is this a 'personal' account type or is this a Business Account with Sync Business Shared Items enabled?
					if ((appConfig.accountType == "personal") || businessSharingEnabled) {
						// Personal account type or syncing Business Shared Items is enabled
						
						// Issue #3336 - Convert driveId to lowercase before any test
						if (appConfig.accountType == "personal") {
							itemToDelete.driveId = transformToLowerCase(itemToDelete.driveId);
						}
						
						// Is the 'drive' where this is to be deleted on 'our' drive or is this a remote 'drive' ?
						if (itemToDelete.driveId != appConfig.defaultDriveId) {
							// The item to delete is on a remote drive ... this must be handled in a specific way
							if (itemToDelete.type == ItemType.dir) {
								// Select the 'remote' database object type using these details
								// Get the DB entry for this 'remote' item
								itemDB.selectRemoteTypeByRemoteDriveId(itemToDelete.driveId, itemToDelete.id, remoteShortcutLinkItem);
							}	
						}
						
						// We potentially now have the correct details to delete in our account
						if (remoteShortcutLinkItem.type == ItemType.remote) {
							// A valid 'remote' DB entry was returned
							if (debugLogging) {addLogEntry("remoteShortcutLinkItem: " ~ to!string(remoteShortcutLinkItem), ["debug"]);}
							// Set actualItemToDelete to this data
							actualItemToDelete = remoteShortcutLinkItem;
							
							// Delete the shortcut reference in the local database
							if (appConfig.accountType == "personal") {
								// Personal Shared Folder deletion message
								if (debugLogging) {addLogEntry("Deleted OneDrive Personal Shared Folder 'Shortcut Link'", ["debug"]);}
							} else {
								// Business Shared Folder deletion message
								if (debugLogging) {addLogEntry("Deleted OneDrive Business Shared Folder 'Shortcut Link'", ["debug"]);}
							}
							
							// Perform action deletion from database
							itemDB.deleteById(remoteShortcutLinkItem.driveId, remoteShortcutLinkItem.id);
						} else {
							// No data was returned, use the original data
							actualItemToDelete = itemToDelete;
						}
					} else {
						// Set actualItemToDelete to original data
						actualItemToDelete = itemToDelete;
					}
					
					// Try the online deletion using the 'actualItemToDelete' values
					try {
						// Create new OneDrive API Instance
						uploadDeletedItemOneDriveApiInstance = new OneDriveApi(appConfig);
						uploadDeletedItemOneDriveApiInstance.initialise();
					
						if (!permanentDelete) {
							// Perform the delete via the default OneDrive API instance
							uploadDeletedItemOneDriveApiInstance.deleteById(actualItemToDelete.driveId, actualItemToDelete.id);
						} else {
							// Perform the permanent delete via the default OneDrive API instance
							uploadDeletedItemOneDriveApiInstance.permanentDeleteById(actualItemToDelete.driveId, actualItemToDelete.id);
						}
						
						// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
						uploadDeletedItemOneDriveApiInstance.releaseCurlEngine();
						uploadDeletedItemOneDriveApiInstance = null;
						// Perform Garbage Collection
						GC.collect();
					
					} catch (OneDriveException e) {
						if (e.httpStatusCode == 404) {
							// item.id, item.eTag could not be found on the specified driveId
							if (verboseLogging) {addLogEntry("OneDrive reported: The resource could not be found to be deleted.", ["verbose"]);}
						}
						
						// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
						uploadDeletedItemOneDriveApiInstance.releaseCurlEngine();
						uploadDeletedItemOneDriveApiInstance = null;
						// Perform Garbage Collection
						GC.collect();
					}
					
					// Delete the reference in the local database - use the original input
					itemDB.deleteById(itemToDelete.driveId, itemToDelete.id);
					
					// Was the original item a 'Shared Folder' ?
					if (remoteShortcutLinkItem.type == ItemType.remote) {
						// Are there any other 'children' for itemToDelete parent ... this parent may have other Shared Folders added to our account that we have not removed ..
						Item[] remainingChildren;
						remainingChildren ~= itemDB.selectChildren(itemToDelete.driveId, itemToDelete.parentId);
						
						// Only if there are zero children for this parent item, remove the 'root' record
						if (count(remainingChildren) == 0) {
							// No more children for this parental object
							itemDB.deleteById(itemToDelete.driveId, itemToDelete.parentId);
						}
					}
				} else {
					// log that this is a dry-run activity
					addLogEntry("dry run - no delete activity");
				}
			} else {
				// --download-only operation, we are not uploading any delete event to OneDrive
				if (debugLogging) {addLogEntry("Not pushing local delete to Microsoft OneDrive due to --download-only being used", ["debug"]);}
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Get the children of an item id from the database
	Item[] getChildren(string driveId, string id) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		Item[] children;
		children ~= itemDB.selectChildren(driveId, id);
		foreach (Item child; children) {
			if (child.type != ItemType.file) {
				// recursively get the children of this child
				children ~= getChildren(child.driveId, child.id);
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// return the database records
		return children;
	}
	
	// Perform a 'reverse' delete of all child objects on OneDrive
	void performReverseDeletionOfOneDriveItems(Item[] children, Item itemToDelete) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Log what is happening
		if (debugLogging) {addLogEntry("Attempting a reverse delete of all child objects from OneDrive", ["debug"]);}
		
		// Create a new API Instance for this thread and initialise it
		OneDriveApi performReverseDeletionOneDriveApiInstance;
		performReverseDeletionOneDriveApiInstance = new OneDriveApi(appConfig);
		performReverseDeletionOneDriveApiInstance.initialise();
		
		foreach_reverse (Item child; children) {
			// Log the action
			if (debugLogging) {addLogEntry("Attempting to delete this child item id: " ~ child.id ~ " from drive: " ~ child.driveId, ["debug"]);}
			
			if (!permanentDelete) {
				// Perform the delete via the default OneDrive API instance
				performReverseDeletionOneDriveApiInstance.deleteById(child.driveId, child.id, child.eTag);
			} else {
				// Perform the permanent delete via the default OneDrive API instance
				performReverseDeletionOneDriveApiInstance.permanentDeleteById(child.driveId, child.id, child.eTag);
			}
			
			// delete the child reference in the local database
			itemDB.deleteById(child.driveId, child.id);
		}
		// Log the action
		if (debugLogging) {addLogEntry("Attempting to delete this parent item id: " ~ itemToDelete.id ~ " from drive: " ~ itemToDelete.driveId, ["debug"]);}
		
		if (!permanentDelete) {
			// Perform the delete via the default OneDrive API instance
			performReverseDeletionOneDriveApiInstance.deleteById(itemToDelete.driveId, itemToDelete.id, itemToDelete.eTag);
		} else {
			// Perform the permanent delete via the default OneDrive API instance
			performReverseDeletionOneDriveApiInstance.permanentDeleteById(itemToDelete.driveId, itemToDelete.id, itemToDelete.eTag);
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		performReverseDeletionOneDriveApiInstance.releaseCurlEngine();
		performReverseDeletionOneDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Create a fake OneDrive response suitable for use with saveItem
	JSONValue createFakeResponse(string path) {
		import std.digest.sha;
		
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Generate a simulated JSON response which can be used
		// At a minimum we need:
		// 1. eTag
		// 2. cTag
		// 3. fileSystemInfo
		// 4. file or folder. if file, hash of file
		// 5. id
		// 6. name
		// 7. parent reference
		
		string fakeDriveId = appConfig.defaultDriveId;
		string fakeRootId = appConfig.defaultRootId;
		SysTime mtime = exists(path) ? timeLastModified(path).toUTC() : Clock.currTime(UTC());
		auto sha1 = new SHA1Digest();
		ubyte[] fakedOneDriveItemValues = sha1.digest(path);
		JSONValue fakeResponse;

		string parentPath = dirName(path);
		if (parentPath != "." && exists(path)) {
			foreach (searchDriveId; onlineDriveDetails.keys) {
				Item databaseItem;
				if (itemDB.selectByPath(parentPath, searchDriveId, databaseItem)) {
					fakeDriveId = databaseItem.driveId;
					fakeRootId = databaseItem.id;
					break; // Exit loop after finding the first match
				}
			}
		}

		fakeResponse = [
			"id": JSONValue(toHexString(fakedOneDriveItemValues)),
			"cTag": JSONValue(toHexString(fakedOneDriveItemValues)),
			"eTag": JSONValue(toHexString(fakedOneDriveItemValues)),
			"fileSystemInfo": JSONValue([
				"createdDateTime": mtime.toISOExtString(),
				"lastModifiedDateTime": mtime.toISOExtString()
			]),
			"name": JSONValue(baseName(path)),
			"parentReference": JSONValue([
				"driveId": JSONValue(fakeDriveId),
				"driveType": JSONValue(appConfig.accountType),
				"id": JSONValue(fakeRootId)
			])
		];

		if (exists(path)) {
			if (isDir(path)) {
				fakeResponse["folder"] = JSONValue("");
			} else {
				string quickXorHash = computeQuickXorHash(path);
				fakeResponse["file"] = JSONValue([
					"hashes": JSONValue(["quickXorHash": JSONValue(quickXorHash)])
				]);
			}
		} else {
			// Assume directory if path does not exist
			fakeResponse["folder"] = JSONValue("");
		}

		if (debugLogging) {addLogEntry("Generated Fake OneDrive Response: " ~ to!string(fakeResponse), ["debug"]);}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// return the generated fake API response
		return fakeResponse;
	}

	// Save JSON item details into the item database
	void saveItem(JSONValue jsonItem) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// jsonItem has to be a valid object
		if (jsonItem.type() == JSONType.object) {
		
			// Issue #3336 - Convert driveId to lowercase
			if (appConfig.accountType == "personal") {
				// We must massage this raw JSON record to force the jsonItem["parentReference"]["driveId"] to lowercase
				if (hasParentReferenceDriveId(jsonItem)) {
					// This JSON record has a driveId we now must manipulate to lowercase
					string originalDriveIdValue = jsonItem["parentReference"]["driveId"].str;
					jsonItem["parentReference"]["driveId"] = transformToLowerCase(originalDriveIdValue);
				}
			}
			
			// Check if the response JSON has an 'id', otherwise makeItem() fails with 'Key not found: id'
			if (hasId(jsonItem)) {
				// Are we in a --upload-only & --remove-source-files scenario?
				// We do not want to add the item to the database in this situation as there is no local reference to the file post file deletion
				// If the item is a directory, we need to add this to the DB, if this is a file, we dont add this, the parent path is not in DB, thus any new files in this directory are not added
				if ((uploadOnly) && (localDeleteAfterUpload) && (isItemFile(jsonItem))) {
					// Log that we skipping adding item to the local DB and the reason why
					if (debugLogging) {addLogEntry("Skipping adding to database as --upload-only & --remove-source-files configured", ["debug"]);}
				} else {
					// What is the JSON item we are trying to create a DB record with?
					if (debugLogging) {addLogEntry("saveItem - creating DB item from this JSON: " ~ sanitiseJSONItem(jsonItem), ["debug"]);}
					
					// Takes a JSON input and formats to an item which can be used by the database
					Item item = makeItem(jsonItem);
					
					// Is this JSON item a 'root' item?
					if ((isItemRoot(jsonItem)) && (item.name == "root")) {
						if (debugLogging) {
							addLogEntry("Updating DB Item object with correct values as this is a 'root' object", ["debug"]);
							addLogEntry(" item.parentId = null", ["debug"]);
							addLogEntry(" item.type = ItemType.root", ["debug"]);
						}
						item.parentId = null; 	// ensures that this database entry has no parent
						item.type = ItemType.root;
						// Check for parentReference
						if (hasParentReference(jsonItem)) {
							// Set the correct item.driveId
							if (debugLogging) {
								addLogEntry("The 'root' JSON Item HAS a parentReference .... setting item.driveId = jsonItem['parentReference']['driveId'].str from the provided JSON record", ["debug"]);
								string logMessage = format(" item.driveId = '%s'", jsonItem["parentReference"]["driveId"].str);
								addLogEntry(logMessage, ["debug"]);
							}
							item.driveId = jsonItem["parentReference"]["driveId"].str;
						
						}
						
						// Issue #3115 - Validate driveId length
						// What account type is this?
						if (appConfig.accountType == "personal") {
							// Issue #3336 - Convert driveId to lowercase before any test
							item.driveId = transformToLowerCase(item.driveId);
							
							// Test driveId length and validation if the driveId we are testing is not equal to appConfig.defaultDriveId
							if (item.driveId != appConfig.defaultDriveId) {
								item.driveId = testProvidedDriveIdForLengthIssue(item.driveId);
							}
						}
						
						// We only should be adding our account 'root' to the database, not shared folder 'root' items
						if (item.driveId != appConfig.defaultDriveId) {
							// Shared Folder drive 'root' object .. we dont want this item
							if (debugLogging) {addLogEntry("NOT adding 'remote root' object to database: " ~ to!string(item), ["debug"]);}
							return;
						}
					}
					
					// Issue #3115 - Validate driveId length
					// What account type is this?
					if (appConfig.accountType == "personal") {
						// Issue #3336 - Convert driveId to lowercase before any test
						item.driveId = transformToLowerCase(item.driveId);
						
						// Test driveId length and validation if the driveId we are testing is not equal to appConfig.defaultDriveId
						if (item.driveId != appConfig.defaultDriveId) {
							item.driveId = testProvidedDriveIdForLengthIssue(item.driveId);
						}
					}
					
					// Add to the local database
					if (debugLogging) {addLogEntry("Saving this DB item record: " ~ to!string(item), ["debug"]);}
					itemDB.upsert(item);
					
					// If we have a remote drive ID, add this to our list of known drive id's
					if (!item.remoteDriveId.empty) {
						// Keep the DriveDetailsCache array with unique entries only
						DriveDetailsCache cachedOnlineDriveData;
						if (!canFindDriveId(item.remoteDriveId, cachedOnlineDriveData)) {
							// Add this driveId to the drive cache
							if (debugLogging) {addLogEntry("Database item is a remote drive object, need to fetch online details for this drive: " ~ to!string(item.remoteDriveId), ["debug"]);}
							addOrUpdateOneDriveOnlineDetails(item.remoteDriveId);
						}
					}
				}
			} else {
				// log error
				addLogEntry("ERROR: OneDrive response missing required 'id' element");
				addLogEntry("ERROR: " ~ sanitiseJSONItem(jsonItem));
			}
		} else {
			// log error
			addLogEntry("ERROR: An error was returned from OneDrive and the resulting response is not a valid JSON object that can be processed.");
			addLogEntry("ERROR: Increase logging verbosity to assist determining why.");
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Save an already created database object into the database
	void saveDatabaseItem(Item newDatabaseItem) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Issue #3115 - Personal Account Shared Folder
		// What account type is this?
		if (appConfig.accountType == "personal") {
			// Issue #3336 - Convert driveId to lowercase for the DB record
			string actualOnlineDriveId = testProvidedDriveIdForLengthIssue(fetchRealOnlineDriveIdentifier(newDatabaseItem.driveId));
			newDatabaseItem.driveId = actualOnlineDriveId;
			
			// Is this a 'remote' DB record
			if (newDatabaseItem.type == ItemType.remote) {
				// Issue #3336 - Convert remoteDriveId to lowercase before any test
				newDatabaseItem.remoteDriveId = transformToLowerCase(newDatabaseItem.remoteDriveId);
			
				// Test remoteDriveId length and validation if the remoteDriveId we are testing is not equal to appConfig.defaultDriveId
				if (newDatabaseItem.remoteDriveId != appConfig.defaultDriveId) {
					// Issue #3136, #3139 #3143
					// Fetch the actual online record for this item
					// This returns the actual OneDrive Personal remoteDriveId value and is 15 character checked
					string actualOnlineRemoteDriveId = testProvidedDriveIdForLengthIssue(fetchRealOnlineDriveIdentifier(newDatabaseItem.remoteDriveId));
					newDatabaseItem.remoteDriveId = actualOnlineRemoteDriveId;
				}
			}
		}
		
		// Add the database record
		if (debugLogging) {addLogEntry("Creating a new database record for a new local path that has been created: " ~ to!string(newDatabaseItem), ["debug"]);}
		itemDB.upsert(newDatabaseItem);
		
		// If we have a remote drive ID, add this to our list of known drive id's
		if (!newDatabaseItem.remoteDriveId.empty) {
			// Keep the DriveDetailsCache array with unique entries only
			DriveDetailsCache cachedOnlineDriveData;
			if (!canFindDriveId(newDatabaseItem.remoteDriveId, cachedOnlineDriveData)) {
				// Add this driveId to the drive cache
				if (debugLogging) {addLogEntry("New database record is a remote drive object, need to fetch online details for this drive: " ~ to!string(newDatabaseItem.remoteDriveId), ["debug"]);}
				addOrUpdateOneDriveOnlineDetails(newDatabaseItem.remoteDriveId);
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Wrapper function for makeDatabaseItem so we can check to ensure that the item has the required hashes
	Item makeItem(JSONValue onedriveJSONItem) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
			
		// Make the DB Item from the JSON data provided
		Item newDatabaseItem = makeDatabaseItem(onedriveJSONItem);
		
		// Is this a 'file' item that has not been deleted? Deleted items have no hash
		if ((newDatabaseItem.type == ItemType.file) && (!isItemDeleted(onedriveJSONItem))) {
			// Does this item have a file size attribute?
			if (hasFileSize(onedriveJSONItem)) {
				// Is the file size greater than 0?
				if (onedriveJSONItem["size"].integer > 0) {
					// Does the DB item have any hashes as per the API provided JSON data?
					if ((newDatabaseItem.quickXorHash.empty) && (newDatabaseItem.sha256Hash.empty)) {
						// Odd .. there is no hash for this item .. why is that?
						// Is there a 'file' JSON element?
						if ("file" in onedriveJSONItem) {
							// Microsoft OneDrive OneNote objects will report as files but have 'application/msonenote' and 'application/octet-stream' as mime types
							if ((isMicrosoftOneNoteMimeType1(onedriveJSONItem)) || (isMicrosoftOneNoteMimeType2(onedriveJSONItem))) {
								// Debug log output that this is a potential OneNote object
								if (debugLogging) {addLogEntry("This item is potentially an associated Microsoft OneNote Object Item", ["debug"]);}
							} else {
								// Not a Microsoft OneNote Mime Type Object ..
								string apiWarningMessage = "WARNING: OneDrive API inconsistency - this file does not have any hash: ";
								// This is computationally expensive .. but we are only doing this if there are no hashes provided
								bool parentInDatabase = itemDB.idInLocalDatabase(newDatabaseItem.driveId, newDatabaseItem.parentId);
								// Is the parent id in the database?
								if (parentInDatabase) {
									// This is again computationally expensive .. calculate this item path to advise the user the actual path of this item that has no hash
									string newItemPath = computeItemPath(newDatabaseItem.driveId, newDatabaseItem.parentId) ~ "/" ~ newDatabaseItem.name;
									addLogEntry(apiWarningMessage ~ newItemPath);
								} else {
									// Parent is not in the database .. why?
									// Check if the parent item had been skipped .. 
									if (newDatabaseItem.parentId in skippedItems) {
										if (debugLogging) {addLogEntry(apiWarningMessage ~ "newDatabaseItem.parentId listed within skippedItems", ["debug"]);}
									} else {
										// Use the item ID .. there is no other reference available, parent is not being skipped, so we should have been able to calculate this - but we could not
										addLogEntry(apiWarningMessage ~ newDatabaseItem.id);
									}
								}
							}
						}	
					}
				} else {
					// zero file size
					if (debugLogging) {addLogEntry("This item file is zero size - potentially no hash provided by the OneDrive API", ["debug"]);}
				}
			}
		}
		
		// OneDrive Personal Account driveId and remoteDriveId length check
		// Issue #3072 (https://github.com/abraunegg/onedrive/issues/3072) illustrated that the OneDrive API is inconsistent in response when the Drive ID starts with a zero ('0')
		// - driveId
		// - remoteDriveId
		// 
		// Example:
		//   024470056F5C3E43 (driveId)
		//   24470056f5c3e43  (remoteDriveId)
		// If this is a OneDrive Personal Account, ensure this value is 16 characters, padded by leading zero's if eventually required
		// What account type is this?
		if (appConfig.accountType == "personal") {
			// Check the newDatabaseItem.remoteDriveId
			if (!newDatabaseItem.remoteDriveId.empty) {
				// Issue #3136, #3139 #3143
				// Test searchItem.driveId length and validation
				// - This check the length, fetch online value and return a 16 character driveId
				newDatabaseItem.remoteDriveId = testProvidedDriveIdForLengthIssue(fetchRealOnlineDriveIdentifier(newDatabaseItem.remoteDriveId));
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// Return the new database item
		return newDatabaseItem;
	}
	
	// For OneDrive Personal Accounts, the case sensitivity depending on the API call means the 'driveId' can be uppercase or lowercase
	// For this application use, this causes issues as, in POSIX environments - 024470056F5C3E43 != 024470056f5c3e43 despite on Windows this being treated as the same
	// This function does NOT do a 15 character driveId validation
	string fetchRealOnlineDriveIdentifier(string inputDriveId) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// What are we doing
		if (debugLogging) {
			string fetchRealValueLogMessage = format("Fetching actual online 'driveId' value for '%s'", inputDriveId);
			addLogEntry(fetchRealValueLogMessage, ["debug"]);
		}
	
		// variables for this function
		JSONValue remoteDriveDetails;
		OneDriveApi fetchDriveDetailsOneDriveApiInstance;
		string outputDriveId;
		
		// Create new OneDrive API Instance
		fetchDriveDetailsOneDriveApiInstance = new OneDriveApi(appConfig);
		fetchDriveDetailsOneDriveApiInstance.initialise();
		
		// Get root details for the provided driveId
		try {
			remoteDriveDetails = fetchDriveDetailsOneDriveApiInstance.getDriveIdRoot(inputDriveId);
		} catch (OneDriveException exception) {
			if (debugLogging) {addLogEntry("remoteDriveDetails = fetchDriveDetailsOneDriveApiInstance.getDriveIdRoot(inputDriveId) generated a OneDriveException", ["debug"]);}
			// Default operation if not 408,429,503,504 errors
			// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
			// Display what the error is
			displayOneDriveErrorMessage(exception.msg, thisFunctionName);
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		fetchDriveDetailsOneDriveApiInstance.releaseCurlEngine();
		fetchDriveDetailsOneDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
		
		// Do we have details we can use?
		if (hasParentReferenceDriveId(remoteDriveDetails)) {
			// We have a [parentReference][driveId] reference driveId to use
			outputDriveId = remoteDriveDetails["parentReference"]["driveId"].str;
		} else {
			// We dont have a value from online we can use
			// Test existing driveId length and validation
			outputDriveId = inputDriveId;
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// Return the outputDriveId
		return outputDriveId;
	}
	
	// Print the fileDownloadFailures and fileUploadFailures arrays if they are not empty
	void displaySyncFailures() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		bool logFailures(string[] failures, string operation) {
			if (failures.empty) return false;

			addLogEntry();
			addLogEntry("Failed items to " ~ operation ~ " to/from Microsoft OneDrive: " ~ to!string(failures.length));

			foreach (failedFile; failures) {
				addLogEntry("Failed to " ~ operation ~ ": " ~ failedFile, ["info", "notify"]);

				foreach (searchDriveId; onlineDriveDetails.keys) {
					Item dbItem;
					if (itemDB.selectByPath(failedFile, searchDriveId, dbItem)) {
						addLogEntry("ERROR: Failed " ~ operation ~ " path found in database, must delete this item from the database .. it should not be in there if the file failed to " ~ operation);
						itemDB.deleteById(dbItem.driveId, dbItem.id);
						if (dbItem.remoteDriveId != null) {
							itemDB.deleteById(dbItem.remoteDriveId, dbItem.remoteId);
						}
					}
				}
			}
			return true;
		}

		bool downloadFailuresLogged = logFailures(fileDownloadFailures, "download");
		bool uploadFailuresLogged = logFailures(fileUploadFailures, "upload");
		syncFailures = downloadFailuresLogged || uploadFailuresLogged;
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Generate a /delta compatible response - for use when we cant actually use /delta
	// This is required when the application is configured to use National Azure AD deployments as these do not support /delta queries
	// The same technique can also be used when we are using --single-directory. The parent objects up to the single directory target can be added,
	// then once the target of the --single-directory request is hit, all of the children of that path can be queried, giving a much more focused
	// JSON response which can then be processed, negating the need to continuously traverse the tree and 'exclude' items
	JSONValue generateDeltaResponse(string pathToQuery = null) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// JSON value which will be responded with
		JSONValue selfGeneratedDeltaResponse;
		
		// Function variables
		bool remotePathObject = false;
		Item searchItem;
		JSONValue rootData;
		JSONValue driveData;
		JSONValue pathData;
		JSONValue topLevelChildren;
		JSONValue[] childrenData;
		string nextLink;
		OneDriveApi generateDeltaResponseOneDriveApiInstance;
		
		// Was a path to query passed in?
		if (pathToQuery.empty) {
			// Will query for the 'root'
			pathToQuery = ".";
		}
		
		// Create new OneDrive API Instance
		generateDeltaResponseOneDriveApiInstance = new OneDriveApi(appConfig);
		generateDeltaResponseOneDriveApiInstance.initialise();
		
		// Is this a --single-directory invocation?
		if (!singleDirectoryScope) {
			// In a --resync scenario, there is no DB data to query, so we have to query the OneDrive API here to get relevant details
			try {
				// Query the OneDrive API, using the path, which will query 'our' OneDrive Account
				pathData = generateDeltaResponseOneDriveApiInstance.getPathDetails(pathToQuery);
				
				// Is the path on OneDrive local or remote to our account drive id?
				if (!isItemRemote(pathData)) {
					// The path we are seeking is local to our account drive id
					searchItem.driveId = pathData["parentReference"]["driveId"].str;
					searchItem.id = pathData["id"].str;
				} else {
					// The path we are seeking is remote to our account drive id
					searchItem.driveId = pathData["remoteItem"]["parentReference"]["driveId"].str;
					searchItem.id = pathData["remoteItem"]["id"].str;
					remotePathObject = true;
					
					// Issue #3115 - Personal Account Shared Folder
					// What account type is this?
					if (appConfig.accountType == "personal") {
						// Issue #3136, #3139 #3143
						// Fetch the actual online record for this item
						// This returns the actual OneDrive Personal driveId value. The check of 'searchItem.driveId' to comply with 16 characters is done below
						string actualOnlineDriveId = fetchRealOnlineDriveIdentifier(searchItem.driveId);
						searchItem.driveId = actualOnlineDriveId;
					}
				}
			} catch (OneDriveException exception) {
				// Display error message
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
				
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				generateDeltaResponseOneDriveApiInstance.releaseCurlEngine();
				generateDeltaResponseOneDriveApiInstance = null;
				
				// Perform Garbage Collection
				GC.collect();
				
				// Must force exit here, allow logging to be done
				forceExit();
			}
		} else {
			// When setSingleDirectoryScope() was called, the following were set to the correct items, even if the path was remote:
			// - singleDirectoryScopeDriveId
			// - singleDirectoryScopeItemId
			// Reuse these prior set values
			searchItem.driveId = singleDirectoryScopeDriveId;
			searchItem.id = singleDirectoryScopeItemId;
		}
		
		// Issue #3072 - Validate searchItem.driveId length
		// What account type is this?
		if (appConfig.accountType == "personal") {
			// Issue #3336 - Convert driveId to lowercase before any test
			searchItem.driveId = transformToLowerCase(searchItem.driveId);
		
			// Test driveId length and validation if the driveId we are testing is not equal to appConfig.defaultDriveId
			if (searchItem.driveId != appConfig.defaultDriveId) {
				searchItem.driveId = testProvidedDriveIdForLengthIssue(searchItem.driveId);
			}
		}
		
		// Before we get any data from the OneDrive API, flag any child object in the database as out-of-sync for this driveId & and object id
		// Downgrade ONLY files associated with this driveId and idToQuery
		if (debugLogging) {addLogEntry("Downgrading all children for this searchItem.driveId (" ~ searchItem.driveId ~ ") and searchItem.id (" ~ searchItem.id ~ ") to an out-of-sync state", ["debug"]);}
		
		Item[] drivePathChildren = getChildren(searchItem.driveId, searchItem.id);
		if (count(drivePathChildren) > 0) {
			// Children to process and flag as out-of-sync	
			foreach (drivePathChild; drivePathChildren) {
				// Flag any object in the database as out-of-sync for this driveId & and object id
				if (debugLogging) {addLogEntry("Downgrading item as out-of-sync: " ~ drivePathChild.id, ["debug"]);}
				itemDB.downgradeSyncStatusFlag(drivePathChild.driveId, drivePathChild.id);
			}
		}
		// Clear DB response array
		drivePathChildren = [];
		
		// Get drive details for the provided driveId
		try {
			driveData = generateDeltaResponseOneDriveApiInstance.getPathDetailsById(searchItem.driveId, searchItem.id);
		} catch (OneDriveException exception) {
			// An error was generated
			if (debugLogging) {addLogEntry("driveData = generateDeltaResponseOneDriveApiInstance.getPathDetailsById(searchItem.driveId, searchItem.id) generated a OneDriveException", ["debug"]);}
			
			// Was this a 403 or 404 ?
			if ((exception.httpStatusCode == 403) || (exception.httpStatusCode == 404)) {
				// The API call returned a 404 error response
				if (debugLogging) {addLogEntry("onlineParentData = onlineParentOneDriveApiInstance.getPathDetailsById(parentDriveId, parentObjectId); generated a 404 - shared folder path does not exist online", ["debug"]);}
				string errorMessage = format("WARNING: The OneDrive Shared Folder link target '%s' cannot be found online using the provided online data.", pathToQuery);
				// detail what this 404 error response means
				addLogEntry();
				addLogEntry(errorMessage);
				addLogEntry("WARNING: This is potentially a broken online OneDrive Shared Folder link or you no longer have access to it. Please correct this error online.");
				addLogEntry();
				
				// Release curl engine
				generateDeltaResponseOneDriveApiInstance.releaseCurlEngine();
				// Free object and memory
				generateDeltaResponseOneDriveApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				
				// Return the generated JSON response
				return selfGeneratedDeltaResponse;
			} else {
				// Default operation if not 408,429,503,504 errors
				// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
				// Display what the error is
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
			}
		}
		
		// Was a valid JSON response for 'driveData' provided?
		if (driveData.type() == JSONType.object) {
			// Dynamic output for a non-verbose run so that the user knows something is happening
			string generatingDeltaResponseMessage = format("Generating a /delta response from the OneDrive API for this Drive ID: %s and Item ID: %s", searchItem.driveId, searchItem.id);
			if (appConfig.verbosityCount == 0) {
				if (!appConfig.suppressLoggingOutput) {
					addProcessingLogHeaderEntry(generatingDeltaResponseMessage, appConfig.verbosityCount);
				}
			} else {
				if (verboseLogging) {addLogEntry(generatingDeltaResponseMessage, ["verbose"]);}
			}
		
			// Process this initial JSON response
			if (!isItemRoot(driveData)) {
				// Are we generating a /delta response for a Shared Folder, if not, then we need to add the drive root details first
				if (!sharedFolderDeltaGeneration) {
					// Get root details for the provided driveId
					try {
						rootData = generateDeltaResponseOneDriveApiInstance.getDriveIdRoot(searchItem.driveId);
					} catch (OneDriveException exception) {
						if (debugLogging) {addLogEntry("rootData = onedrive.getDriveIdRoot(searchItem.driveId) generated a OneDriveException", ["debug"]);}
						// Default operation if not 408,429,503,504 errors
						// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
						// Display what the error is
						displayOneDriveErrorMessage(exception.msg, thisFunctionName);
					}
					// Add driveData JSON data to array
					if (verboseLogging) {addLogEntry("Adding OneDrive root details for processing", ["verbose"]);}
					childrenData ~= rootData;
				}
			}
			
			// Add driveData JSON data to array
			if (verboseLogging) {addLogEntry("Adding OneDrive parent folder details for processing", ["verbose"]);}
			
			// What 'driveData' are we adding?
			if (debugLogging) {
				addLogEntry("adding this 'driveData' to childrenData = " ~ to!string(driveData), ["debug"]);
			}
			
			// add the responded 'driveData' to the childrenData to process later
			childrenData ~= driveData;
		} else {
			// driveData is an invalid JSON object
			addLogEntry("CODING TO DO: The query of OneDrive API to getPathDetailsById generated an invalid JSON response - thus we cant build our own /delta simulated response ... how to handle?");
			// Release curl engine
			generateDeltaResponseOneDriveApiInstance.releaseCurlEngine();
			// Free object and memory
			generateDeltaResponseOneDriveApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			
			// Must force exit here, allow logging to be done
			forceExit();
		}
		
		// For each child object, query the OneDrive API
		while (true) {
			// Check if exitHandlerTriggered is true
			if (exitHandlerTriggered) {
				// break out of the 'while (true)' loop
				break;
			}
			// query top level children
			try {
				topLevelChildren = generateDeltaResponseOneDriveApiInstance.listChildren(searchItem.driveId, searchItem.id, nextLink);
			} catch (OneDriveException exception) {
				// OneDrive threw an error
				if (debugLogging) {
					addLogEntry(debugLogBreakType1, ["debug"]);
					addLogEntry("Query Error: topLevelChildren = generateDeltaResponseOneDriveApiInstance.listChildren(searchItem.driveId, searchItem.id, nextLink)", ["debug"]);
					addLogEntry("driveId:   " ~ searchItem.driveId, ["debug"]);
					addLogEntry("idToQuery: " ~ searchItem.id, ["debug"]);
					addLogEntry("nextLink:  " ~ nextLink, ["debug"]);
				}
				// Default operation if not 408,429,503,504 errors
				// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
				// Display what the error is
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
			}
			
			// Process top level children
			if (!remotePathObject) {
				// Main account root folder
				if (verboseLogging) {addLogEntry("Adding " ~ to!string(count(topLevelChildren["value"].array)) ~ " OneDrive items for processing from the OneDrive 'root' Folder", ["verbose"]);}
			} else {
				// Shared Folder
				if (verboseLogging) {addLogEntry("Adding " ~ to!string(count(topLevelChildren["value"].array)) ~ " OneDrive items for processing from the OneDrive Shared Folder", ["verbose"]);}
			}
			
			foreach (child; topLevelChildren["value"].array) {
				// Check for any Client Side Filtering here ... we should skip querying the OneDrive API for 'folders' that we are going to just process and skip anyway.
				// This avoids needless calls to the OneDrive API, and potentially speeds up this process.
				if (!checkJSONAgainstClientSideFiltering(child)) {
					// add this child to the array of objects
					childrenData ~= child;
					// is this child a folder?
					if (isItemFolder(child)) {
						// We have to query this folders children if childCount > 0
						if (child["folder"]["childCount"].integer > 0){
							// This child folder has children
							string childIdToQuery = child["id"].str;
							string childDriveToQuery = child["parentReference"]["driveId"].str;
							auto childParentPath = child["parentReference"]["path"].str.split(":");
							string folderPathToScan = childParentPath[1] ~ "/" ~ child["name"].str;
							
							string pathForLogging;
							// Are we in a --single-directory situation? If we are, the path we are using for logging needs to use the input path as a base
							if (singleDirectoryScope) {
								pathForLogging = appConfig.getValueString("single_directory") ~ "/" ~ child["name"].str;
							} else {
								pathForLogging = child["name"].str;
							}
							
							// Query the children of this item
							JSONValue[] grandChildrenData = queryForChildren(childDriveToQuery, childIdToQuery, folderPathToScan, pathForLogging);
							foreach (grandChild; grandChildrenData.array) {
								// add the grandchild to the array
								childrenData ~= grandChild;
							}
						}
					}
					
					// As we are generating a /delta response we need to check if this 'child' JSON is a 'remoteItem' and then handle appropriately
					// Is this a remote folder JSON ?
					if (isItemRemote(child)) {
						// Check account type
						if (appConfig.accountType == "personal") {
							// The folder is a remote item ... OneDrive Personal Shared Folder
							if (debugLogging) {addLogEntry("The JSON data indicates this is most likely a OneDrive Personal Shared Folder Link added by 'Add shortcut to My files'", ["debug"]);}
							// It is a 'remote' JSON item denoting a potential shared folder
							// Create a 'root' and 'Shared Folder' DB Tie Records for this JSON object in a consistent manner
							createRequiredSharedFolderDatabaseRecords(child);
						}
					
						if (appConfig.accountType == "business") {
							// The folder is a remote item ... OneDrive Business Shared Folder
							if (debugLogging) {addLogEntry("The JSON data indicates this is most likely a OneDrive Shared Business Folder Link added by 'Add shortcut to My files'", ["debug"]);}
							
							// Is Shared Business Folder Syncing actually enabled?
							if (appConfig.getValueBool("sync_business_shared_items")) {
								// Shared Business Folder Syncing IS enabled
								// It is a 'remote' JSON item denoting a potential shared folder
								// Create a 'root' and 'Shared Folder' DB Tie Records for this JSON object in a consistent manner
								createRequiredSharedFolderDatabaseRecords(child);
							}
						}
					}
				}
			}
			
			// If a collection exceeds the default page size (200 items), the @odata.nextLink property is returned in the response 
			// to indicate more items are available and provide the request URL for the next page of items.
			if ("@odata.nextLink" in topLevelChildren) {
				// Update nextLink to next changeSet bundle
				if (debugLogging) {addLogEntry("Setting nextLink to (@odata.nextLink): " ~ nextLink, ["debug"]);}
				nextLink = topLevelChildren["@odata.nextLink"].str;
			} else break;
			
			// Sleep for a while to avoid busy-waiting
			Thread.sleep(dur!"msecs"(100)); // Adjust the sleep duration as needed
		}
		
		if (appConfig.verbosityCount == 0) {
			// Dynamic output for a non-verbose run so that the user knows something is happening
			if (!appConfig.suppressLoggingOutput) {
				// Close out the '....' being printed to the console
				completeProcessingDots();
			}
		}
		
		// Craft response from all returned JSON elements
		selfGeneratedDeltaResponse = [
						"@odata.context": JSONValue("https://graph.microsoft.com/v1.0/$metadata#Collection(driveItem)"),
						"value": JSONValue(childrenData.array)
						];
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		generateDeltaResponseOneDriveApiInstance.releaseCurlEngine();
		generateDeltaResponseOneDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// Return the generated JSON response
		return selfGeneratedDeltaResponse;
	}
	
	// Query the OneDrive API for the specified child id for any children objects
	JSONValue[] queryForChildren(string driveId, string idToQuery, string childParentPath, string pathForLogging) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
				
		// function variables
		JSONValue thisLevelChildren;
		JSONValue[] thisLevelChildrenData;
		string nextLink;
		
		// Create new OneDrive API Instance
		OneDriveApi queryChildrenOneDriveApiInstance;
		queryChildrenOneDriveApiInstance = new OneDriveApi(appConfig);
		queryChildrenOneDriveApiInstance.initialise();
		
		// Issue #3115 - Validate driveId length
		// What account type is this?
		if (appConfig.accountType == "personal") {
			// Issue #3336 - Convert driveId to lowercase before any test
			driveId = transformToLowerCase(driveId);
		
			// Test driveId length and validation if the driveId we are testing is not equal to appConfig.defaultDriveId
			if (driveId != appConfig.defaultDriveId) {
				driveId = testProvidedDriveIdForLengthIssue(driveId);
			}
		}
		
		while (true) {
			// Check if exitHandlerTriggered is true
			if (exitHandlerTriggered) {
				// break out of the 'while (true)' loop
				break;
			}
			
			// Query this level children
			try {
				thisLevelChildren = queryThisLevelChildren(driveId, idToQuery, nextLink, queryChildrenOneDriveApiInstance);
			} catch (OneDriveException exception) {
				// MAY NEED FUTURE WORK HERE .. YET TO TRIGGER THIS
				addLogEntry("CODING TO DO: EXCEPTION HANDLING NEEDED: thisLevelChildren = queryThisLevelChildren(driveId, idToQuery, nextLink, queryChildrenOneDriveApiInstance)");
			}
			
			if (appConfig.verbosityCount == 0) {
				// Dynamic output for a non-verbose run so that the user knows something is happening
				if (!appConfig.suppressLoggingOutput) {
					addProcessingDotEntry();
				}
			}
			
			// Was a paging token error detected? 
			if ((thisLevelChildren.type() == JSONType.string) && (thisLevelChildren.str == "INVALID_PAGING_TOKEN")) {
				// Invalid paging token: failed to parse integer value from token
				if (debugLogging) addLogEntry("Upstream detected invalid paging token – clearing nextLink and retrying", ["debug"]);
				nextLink = null;
				thisLevelChildren = queryThisLevelChildren(driveId, idToQuery, nextLink, queryChildrenOneDriveApiInstance);
			}
			
			// Was a valid JSON response for 'thisLevelChildren' provided?
			if (thisLevelChildren.type() == JSONType.object) {
				// process this level children
				if (!childParentPath.empty) {
					// We dont use childParentPath to log, as this poses an information leak risk.
					// The full parent path of the child, as per the JSON might be:
					//   /Level 1/Level 2/Level 3/Child Shared Folder/some folder/another folder
					// But 'Child Shared Folder' is what is shared, thus '/Level 1/Level 2/Level 3/' is a potential information leak if logged.
					// Plus, the application output now shows accurately what is being shared - so that is a good thing.
					if (verboseLogging) {addLogEntry("Adding " ~ to!string(count(thisLevelChildren["value"].array)) ~ " OneDrive JSON items for further processing from " ~ pathForLogging, ["verbose"]);}
				}
				foreach (child; thisLevelChildren["value"].array) {
					// Check for any Client Side Filtering here ... we should skip querying the OneDrive API for 'folders' that we are going to just process and skip anyway.
					// This avoids needless calls to the OneDrive API, and potentially speeds up this process.
					if (!checkJSONAgainstClientSideFiltering(child)) {
						// add this child to the array of objects
						thisLevelChildrenData ~= child;
						// is this child a folder?
						if (isItemFolder(child)){
							// We have to query this folders children if childCount > 0
							if (child["folder"]["childCount"].integer > 0){
								// This child folder has children
								string childIdToQuery = child["id"].str;
								string childDriveToQuery = child["parentReference"]["driveId"].str;
								auto grandchildParentPath = child["parentReference"]["path"].str.split(":");
								string folderPathToScan = grandchildParentPath[1] ~ "/" ~ child["name"].str;
								string newLoggingPath = pathForLogging ~ "/" ~ child["name"].str;
								JSONValue[] grandChildrenData = queryForChildren(childDriveToQuery, childIdToQuery, folderPathToScan, newLoggingPath);
								foreach (grandChild; grandChildrenData.array) {
									// add the grandchild to the array
									thisLevelChildrenData ~= grandChild;
								}
							}
						}
					}
				}
				
				// If a collection exceeds the default page size (200 items), the @odata.nextLink property is returned in the response 
				// to indicate more items are available and provide the request URL for the next page of items.
				if ("@odata.nextLink" in thisLevelChildren) {
					// Update nextLink to next changeSet bundle
					nextLink = thisLevelChildren["@odata.nextLink"].str;
					if (debugLogging) {addLogEntry("Setting nextLink to (@odata.nextLink): " ~ nextLink, ["debug"]);}
				} else break;
			
			} else {
				// Invalid JSON response when querying this level children
				if (debugLogging) {addLogEntry("INVALID JSON response when attempting a retry of parent function - queryForChildren(driveId, idToQuery, childParentPath, pathForLogging)", ["debug"]);}
				
				// retry thisLevelChildren = queryThisLevelChildren
				if (debugLogging) {addLogEntry("Thread sleeping for an additional 30 seconds", ["debug"]);}
				Thread.sleep(dur!"seconds"(30));
				if (debugLogging) {addLogEntry("Retry this call thisLevelChildren = queryThisLevelChildren(driveId, idToQuery, nextLink, queryChildrenOneDriveApiInstance)", ["debug"]);}
				thisLevelChildren = queryThisLevelChildren(driveId, idToQuery, nextLink, queryChildrenOneDriveApiInstance);
			}
			
			// Sleep for a while to avoid busy-waiting
			Thread.sleep(dur!"msecs"(100)); // Adjust the sleep duration as needed
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		queryChildrenOneDriveApiInstance.releaseCurlEngine();
		queryChildrenOneDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// return response
		return thisLevelChildrenData;
	}
	
	// Query the OneDrive API for the child objects for this element
	JSONValue queryThisLevelChildren(string driveId, string idToQuery, string nextLink, OneDriveApi queryChildrenOneDriveApiInstance) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Issue #3115 - Validate driveId length
		// - The function 'queryForChildren' checks the 'driveId' value and that value is the input to this function.
		//   It is redundant to then check 'driveid' again as this is not changed when this function is called
		
		// function variables 
		JSONValue thisLevelChildren;
		
		// query children
		try {
			// attempt API call
			if (debugLogging) {addLogEntry("Attempting Query: thisLevelChildren = queryChildrenOneDriveApiInstance.listChildren(driveId, idToQuery, nextLink)", ["debug"]);}
			thisLevelChildren = queryChildrenOneDriveApiInstance.listChildren(driveId, idToQuery, nextLink);
			if (debugLogging) {addLogEntry("Query 'thisLevelChildren = queryChildrenOneDriveApiInstance.listChildren(driveId, idToQuery, nextLink)' performed successfully", ["debug"]);}
		} catch (OneDriveException exception) {
			// OneDrive threw an error
			if (debugLogging) {
				addLogEntry(debugLogBreakType1, ["debug"]);
				addLogEntry("Query Error: thisLevelChildren = queryChildrenOneDriveApiInstance.listChildren(driveId, idToQuery, nextLink)", ["debug"]);
				addLogEntry("driveId: " ~ driveId, ["debug"]);
				addLogEntry("idToQuery: " ~ idToQuery, ["debug"]);
				addLogEntry("nextLink: " ~ nextLink, ["debug"]);
			}
			
			// Default operation if not 408,429,503,504 errors
			// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
			// Display what the error is
			displayOneDriveErrorMessage(exception.msg, thisFunctionName);
			
			// With the error displayed, testing of PR #3381 for #3375 generated this error:
			//	Error Message:       HTTP request returned status code 400 (Bad Request)
			//	Error Reason:        Invalid paging token: failed to parse integer value from token.
			if ((exception.httpStatusCode == 400) && (exception.msg.canFind("Invalid paging token")))  {
				// Log and return a known marker that bypasses JSONType.object check
				if (debugLogging) addLogEntry("Detected invalid paging token – signaling upstream", ["debug"]);
				return JSONValue("INVALID_PAGING_TOKEN");
			}
			
			// Generic failure
			return thisLevelChildren;
		}
				
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// return response
		return thisLevelChildren;
	}
	
	// Traverses the provided path online, via the OneDrive API, following correct parent driveId and itemId elements across the account
	// to find if this full path exists. If this path exists online, the last item in the object path will be returned as a full JSON item.
	//
	// If the createPathIfMissing = false + no path exists online, a null invalid JSON item will be returned.
	// If the createPathIfMissing = true + no path exists online, the requested path will be created in the correct location online. The resulting
	// response to the directory creation will then be returned.
	//
	// This function also ensures that each path in the requested path actually matches the requested element to ensure that the OneDrive API response
	// is not falsely matching a 'case insensitive' match to the actual request which is a POSIX compliance issue.
	JSONValue queryOneDriveForSpecificPathAndCreateIfMissing(string thisNewPathToSearch, bool createPathIfMissing) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// function variables
		JSONValue getPathDetailsAPIResponse;
		string currentPathTree;
		Item parentDetails;
		JSONValue topLevelChildren;
		string nextLink;
		bool directoryFoundOnline = false;
		bool posixIssue = false;
		
		// Create a new API Instance for this thread and initialise it
		OneDriveApi queryOneDriveForSpecificPath;
		queryOneDriveForSpecificPath = new OneDriveApi(appConfig);
		queryOneDriveForSpecificPath.initialise();
		
		foreach (thisFolderName; pathSplitter(thisNewPathToSearch)) {
			if (debugLogging) {addLogEntry("Testing for the existence online of this folder path: " ~ thisFolderName, ["debug"]);}
			directoryFoundOnline = false;
			
			// If this is '.' this is the account root
			if (thisFolderName == ".") {
				currentPathTree = thisFolderName;
			} else {
				currentPathTree = currentPathTree ~ "/" ~ thisFolderName;
			}
			
			// What path are we querying
			if (debugLogging) {addLogEntry("Attempting to query OneDrive for this path: " ~ currentPathTree, ["debug"]);}
			
			// What query do we use?
			if (thisFolderName == ".") {
				// Query the root, set the right details
				try {
					getPathDetailsAPIResponse = queryOneDriveForSpecificPath.getPathDetails(currentPathTree);
					parentDetails = makeItem(getPathDetailsAPIResponse);
					// Save item to the database
					saveItem(getPathDetailsAPIResponse);
					directoryFoundOnline = true;
				} catch (OneDriveException exception) {
					// Default operation if not 408,429,503,504 errors
					// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
					// Display what the error is
					displayOneDriveErrorMessage(exception.msg, thisFunctionName);
				}
			} else {
				// Ensure we have a valid driveId to search here
				if (parentDetails.driveId.empty) {
					parentDetails.driveId = appConfig.defaultDriveId;
				}
				
				// Issue #3336 - Convert driveId to lowercase before any test
				if (appConfig.accountType == "personal") {
					parentDetails.driveId = transformToLowerCase(parentDetails.driveId);
				}
				
				// If the prior JSON 'getPathDetailsAPIResponse' is on this account driveId .. then continue to use getPathDetails
				if (parentDetails.driveId == appConfig.defaultDriveId) {
				
					try {
						// Query OneDrive API for this path
						getPathDetailsAPIResponse = queryOneDriveForSpecificPath.getPathDetails(currentPathTree);
						
						// Portable Operating System Interface (POSIX) testing of JSON response from OneDrive API
						if (hasName(getPathDetailsAPIResponse)) {
							// Perform the POSIX evaluation test against the names
							if (performPosixTest(thisFolderName, getPathDetailsAPIResponse["name"].str)) {
								throw new PosixException(thisFolderName, getPathDetailsAPIResponse["name"].str);
							}
						} else {
							throw new JsonResponseException("Unable to perform POSIX test as the OneDrive API request generated an invalid JSON response");
						}
						
						// No POSIX issue with requested path element
						parentDetails = makeItem(getPathDetailsAPIResponse);
						// Save item to the database
						saveItem(getPathDetailsAPIResponse);
						directoryFoundOnline = true;
						
						// Is this JSON a remote object
						if (debugLogging) {addLogEntry("Testing if this is a remote Shared Folder", ["debug"]);}
						if (isItemRemote(getPathDetailsAPIResponse)) {
							// Remote Directory .. need a DB Tie Record
							createDatabaseTieRecordForOnlineSharedFolder(parentDetails);
							
							// Temp DB Item to bind the 'remote' path to our parent path
							Item tempDBItem;
							// Set the name
							tempDBItem.name = parentDetails.name;
							// Set the correct item type
							tempDBItem.type = ItemType.dir;
							// Set the right elements using the 'remote' of the parent as the 'actual' for this DB Tie
							tempDBItem.driveId = parentDetails.remoteDriveId;
							tempDBItem.id = parentDetails.remoteId;
							// Set the correct mtime
							tempDBItem.mtime = parentDetails.mtime;
							
							// Update parentDetails to use this temp record
							parentDetails = tempDBItem;
						}
					} catch (OneDriveException exception) {
						if (exception.httpStatusCode == 404) {
							directoryFoundOnline = false;
						} else {
							// Default operation if not 408,429,503,504 errors
							// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
							// Display what the error is
							displayOneDriveErrorMessage(exception.msg, thisFunctionName);
						}
					} catch (PosixException e) {
						// Display POSIX error message
						displayPosixErrorMessage(e.msg);
						addLogEntry("ERROR: Requested directory to search for and potentially create has a 'case-insensitive match' to an existing directory on Microsoft OneDrive online.");
						addLogEntry("ERROR: To resolve, rename this local directory: " ~ currentPathTree);
					} catch (JsonResponseException e) {
						if (debugLogging) {addLogEntry(e.msg, ["debug"]);}
					}
				} else {
					// parentDetails.driveId is not the account drive id - thus will be a remote shared item
					if (debugLogging) {addLogEntry("This parent directory is a remote object this next path will be on a remote drive", ["debug"]);}
					
					// For this parentDetails.driveId, parentDetails.id object, query the OneDrive API for it's children
					while (true) {
						// Check if exitHandlerTriggered is true
						if (exitHandlerTriggered) {
							// break out of the 'while (true)' loop
							break;
						}
						// Query this remote object for its children
						topLevelChildren = queryOneDriveForSpecificPath.listChildren(parentDetails.driveId, parentDetails.id, nextLink);
						// Process each child
						foreach (child; topLevelChildren["value"].array) {
							// Is this child a folder?
							if (isItemFolder(child)) {
								// Is this the child folder we are looking for, and is a POSIX match?
								if (child["name"].str == thisFolderName) {
									// EXACT MATCH including case sensitivity: Flag that we found the folder online 
									directoryFoundOnline = true;
									// Use these details for the next entry path
									getPathDetailsAPIResponse = child;
									parentDetails = makeItem(getPathDetailsAPIResponse);
									// Save item to the database
									saveItem(getPathDetailsAPIResponse);
									// No need to continue searching
									break;
								} else {
									string childAsLower = toLower(child["name"].str);
									string thisFolderNameAsLower = toLower(thisFolderName);
									
									try {
										if (childAsLower == thisFolderNameAsLower) {	
											// This is a POSIX 'case in-sensitive match' ..... 
											// Local item name has a 'case-insensitive match' to an existing item on OneDrive
											posixIssue = true;
											throw new PosixException(thisFolderName, child["name"].str);
										}
									} catch (PosixException e) {
										// Display POSIX error message
										displayPosixErrorMessage(e.msg);
										addLogEntry("ERROR: Requested directory to search for and potentially create has a 'case-insensitive match' to an existing directory on Microsoft OneDrive online.");
										addLogEntry("ERROR: To resolve, rename this local directory: " ~ currentPathTree);
									}
								}
							}
						}
						
						if (directoryFoundOnline) {
							// We found the folder, no need to continue searching nextLink data
							break;
						}
						
						// If a collection exceeds the default page size (200 items), the @odata.nextLink property is returned in the response 
						// to indicate more items are available and provide the request URL for the next page of items.
						if ("@odata.nextLink" in topLevelChildren) {
							// Update nextLink to next changeSet bundle
							if (debugLogging) {addLogEntry("Setting nextLink to (@odata.nextLink): " ~ nextLink, ["debug"]);}
							nextLink = topLevelChildren["@odata.nextLink"].str;
						} else break;
						
						// Sleep for a while to avoid busy-waiting
						Thread.sleep(dur!"msecs"(100)); // Adjust the sleep duration as needed
					}
				}
			}
			
			// If we did not find the folder, we need to create this folder
			if (!directoryFoundOnline) {
				// Folder not found online
				// Set any response to be an invalid JSON item
				getPathDetailsAPIResponse = null;
				// Was there a POSIX issue?
				if (!posixIssue) {
					// No POSIX issue
					if (createPathIfMissing) {
						// Create this path as it is missing on OneDrive online and there is no POSIX issue with a 'case-insensitive match'
						if (debugLogging) {
							addLogEntry("FOLDER NOT FOUND ONLINE AND WE ARE REQUESTED TO CREATE IT", ["debug"]);
							addLogEntry("Create folder on this drive:             " ~ parentDetails.driveId, ["debug"]);
							addLogEntry("Create folder as a child on this object: " ~ parentDetails.id, ["debug"]);
							addLogEntry("Create this folder name:                 " ~ thisFolderName, ["debug"]);
						}
						
						// Generate the JSON needed to create the folder online
						JSONValue newDriveItem = [
								"name": JSONValue(thisFolderName),
								"folder": parseJSON("{}")
						];
					
						JSONValue createByIdAPIResponse;
						// Submit the creation request
						// Fix for https://github.com/skilion/onedrive/issues/356
						if (!dryRun) {
							try {
								// Attempt to create a new folder on the configured parent driveId & parent id
								createByIdAPIResponse = queryOneDriveForSpecificPath.createById(parentDetails.driveId, parentDetails.id, newDriveItem);
								// Is the response a valid JSON object - validation checking done in saveItem
								saveItem(createByIdAPIResponse);
								// Set getPathDetailsAPIResponse to createByIdAPIResponse
								getPathDetailsAPIResponse = createByIdAPIResponse;
							} catch (OneDriveException e) {
								// 409 - API Race Condition
								if (e.httpStatusCode == 409) {
									// When we attempted to create it, OneDrive responded that it now already exists
									if (verboseLogging) {addLogEntry("OneDrive reported that " ~ thisFolderName ~ " already exists .. OneDrive API race condition", ["verbose"]);}
								} else {
									// some other error from OneDrive was returned - display what it is
									addLogEntry("OneDrive generated an error when creating this path: " ~ thisFolderName);
									displayOneDriveErrorMessage(e.msg, thisFunctionName);
								}
							}
						} else {
							// Simulate a successful 'directory create' & save it to the dryRun database copy
							// The simulated response has to pass 'makeItem' as part of saveItem
							auto fakeResponse = createFakeResponse(thisNewPathToSearch);
							// Save item to the database
							saveItem(fakeResponse);
						}
					}
				}
			}
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		queryOneDriveForSpecificPath.releaseCurlEngine();
		queryOneDriveForSpecificPath = null;
		// Perform Garbage Collection
		GC.collect();
		
		// Output our search results
		if (debugLogging) {addLogEntry("queryOneDriveForSpecificPathAndCreateIfMissing.getPathDetailsAPIResponse = " ~ to!string(getPathDetailsAPIResponse), ["debug"]);}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// return JSON result
		return getPathDetailsAPIResponse;
	}
	
	// Delete an item by it's path
	// This function is only used in --monitor mode to remove a directory online
	void deleteByPath(string path) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// function variables
		Item dbItem;
		
		// Need to check all driveid's we know about, not just the defaultDriveId
		bool itemInDB = false;
		foreach (searchDriveId; onlineDriveDetails.keys) {
			if (itemDB.selectByPath(path, searchDriveId, dbItem)) {
				// item was found in the DB
				itemInDB = true;
				break;
			}
		}
		
		// Was the item found in the database?
		if (!itemInDB) {
			// path to delete is not in the local database ..
			// was this a --remove-directory attempt?
			if (!appConfig.getValueBool("monitor")) {
				// --remove-directory deletion attempt
				addLogEntry("The item to delete is not in the local database - unable to delete online");
				return;
			} else {
				// normal use .. --monitor being used
				throw new SyncException("The item to delete is not in the local database");
			}
		}
		
		// This needs to be enforced as we have to know the parent id of the object being deleted
		if (dbItem.parentId == null) {
			// the item is a remote folder, need to do the operation on the parent
			enforce(itemDB.selectByPathIncludingRemoteItems(path, appConfig.defaultDriveId, dbItem));
		}
		
		try {
			if (noRemoteDelete) {
				// do not process remote delete
				if (verboseLogging) {addLogEntry("Skipping remote delete as --upload-only & --no-remote-delete configured", ["verbose"]);}
			} else {
				uploadDeletedItem(dbItem, path);
			}
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) {
				addLogEntry(e.msg);
			} else {
				// display what the error is
				displayOneDriveErrorMessage(e.msg, thisFunctionName);
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Delete an item by it's path
	// Delete a directory on OneDrive without syncing. This function is only used with --remove-directory
	void deleteByPathNoSync(string path) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// Attempt to delete the requested path within OneDrive without performing a sync
		addLogEntry("Attempting to delete the requested path within Microsoft OneDrive");
		
		// function variables
		JSONValue getPathDetailsAPIResponse;
		OneDriveApi deleteByPathNoSyncAPIInstance;
		
		// test if the path we are going to exists on OneDrive
		try {
			// Create a new API Instance for this thread and initialise it
			deleteByPathNoSyncAPIInstance = new OneDriveApi(appConfig);
			deleteByPathNoSyncAPIInstance.initialise();
			getPathDetailsAPIResponse = deleteByPathNoSyncAPIInstance.getPathDetails(path);
			
			// If we get here, no error, the path to delete exists online

		} catch (OneDriveException exception) {
		
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			deleteByPathNoSyncAPIInstance.releaseCurlEngine();
			deleteByPathNoSyncAPIInstance = null;
			// Perform Garbage Collection
			GC.collect();
		
			// Log that an error was generated
			if (debugLogging) {addLogEntry("deleteByPathNoSyncAPIInstance.getPathDetails(path) generated a OneDriveException", ["debug"]);}
			if (exception.httpStatusCode == 404) {
				// The directory was not found on OneDrive - no need to delete it
				addLogEntry("The requested directory to delete was not found on OneDrive - skipping removing the remote directory online as it does not exist");
				return;
			}
			
			// Default operation if not 408,429,503,504 errors
			// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
			// Display what the error is
			displayOneDriveErrorMessage(exception.msg, thisFunctionName);
			return;	
		}
		
		// Make a DB item from the JSON data that was returned via the API call
		Item deletionItem = makeItem(getPathDetailsAPIResponse);
		
		// Is the item to remove the correct type
		if (deletionItem.type == ItemType.dir) {
			// Item is a directory to remove
			// Log that the path | item was found, is a directory
			addLogEntry("The requested directory to delete was found on OneDrive - attempting deletion");
			
			// Try the online deletion
			try {
				if (!permanentDelete) {
					// Perform the delete via the default OneDrive API instance
					deleteByPathNoSyncAPIInstance.deleteById(deletionItem.driveId, deletionItem.id);
				} else {
					// Perform the permanent delete via the default OneDrive API instance
					deleteByPathNoSyncAPIInstance.permanentDeleteById(deletionItem.driveId, deletionItem.id);
				}
				// If we get here without error, directory was deleted
				addLogEntry("The requested directory to delete online has been deleted");
			} catch (OneDriveException exception) {
				// Display what the error is
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
			}
		} else {
			// --remove-directory is for removing directories
			// Log that the path | item was found, is a directory
			addLogEntry("The requested path to delete is not a directory - aborting deletion attempt");
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		deleteByPathNoSyncAPIInstance.releaseCurlEngine();
		deleteByPathNoSyncAPIInstance = null;
		// Perform Garbage Collection
		GC.collect();
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_move
	// This function is only called in monitor mode when an move event is coming from
	// inotify and we try to move the item.
	void uploadMoveItem(string oldPath, string newPath) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Log that we are doing a move
		addLogEntry("Moving " ~ oldPath ~ " to " ~ newPath);
		// Is this move unwanted?
		bool unwanted = false;
		// Item variables
		Item oldItem, newItem, parentItem;
		
		// This not a Client Side Filtering check, nor a Microsoft Check, but is a sanity check that the path provided is UTF encoded correctly
		// Check the std.encoding of the path against: Unicode 5.0, ASCII, ISO-8859-1, ISO-8859-2, WINDOWS-1250, WINDOWS-1251, WINDOWS-1252
		if (!unwanted) {
			if(!isValid(newPath)) {
				// Path is not valid according to https://dlang.org/phobos/std_encoding.html
				addLogEntry("Skipping item - invalid character encoding sequence: " ~ newPath, ["info", "notify"]);
				unwanted = true;
			}
		}
		
		// Check this path against the Client Side Filtering Rules
		// - check_nosync
		// - skip_dotfiles
		// - skip_symlinks
		// - skip_file
		// - skip_dir
		// - sync_list
		// - skip_size
		if (!unwanted) {
			unwanted = checkPathAgainstClientSideFiltering(newPath);
		}
		
		// Check this path against the Microsoft Naming Conventions & Restrictions
		// - Check path against Microsoft OneDrive restriction and limitations about Windows naming for files and folders
		// - Check path for bad whitespace items
		// - Check path for HTML ASCII Codes
		// - Check path for ASCII Control Codes
		if (!unwanted) {
			unwanted = checkPathAgainstMicrosoftNamingRestrictions(newPath);
		}
		
		// 'newPath' has passed client side filtering validation
		if (!unwanted) {
		
			if (!itemDB.selectByPath(oldPath, appConfig.defaultDriveId, oldItem)) {
				// The old path|item is not synced with the database, upload as a new file
				addLogEntry("Moved local item was not in-sync with local database - uploading as new item");
				scanLocalFilesystemPathForNewData(newPath);
				return;
			}
		
			if (oldItem.parentId == null) {
				// the item is a remote folder, need to do the operation on the parent
				enforce(itemDB.selectByPathIncludingRemoteItems(oldPath, appConfig.defaultDriveId, oldItem));
			}
		
			if (itemDB.selectByPath(newPath, appConfig.defaultDriveId, newItem)) {
				// the destination has been overwritten
				addLogEntry("Moved local item overwrote an existing item - deleting old online item");
				uploadDeletedItem(newItem, newPath);
			}
			
			if (!itemDB.selectByPath(dirName(newPath), appConfig.defaultDriveId, parentItem)) {
				// the parent item is not in the database
				throw new SyncException("Can't move an item to an unsynchronised directory");
			}
		
			if (oldItem.driveId != parentItem.driveId) {
				// items cannot be moved between drives
				uploadDeletedItem(oldItem, oldPath);
				
				// what sort of move is this?
				if (isFile(newPath)) {
					// newPath is a file
					uploadNewFile(newPath);
				} else {
					// newPath is a directory
					scanLocalFilesystemPathForNewData(newPath);
				}
			} else {
				if (!exists(newPath)) {
					// is this --monitor use?
					if (appConfig.getValueBool("monitor")) {
						if (verboseLogging) {addLogEntry("uploadMoveItem target has disappeared: " ~ newPath, ["verbose"]);}
						return;
					}
				}
			
				// Configure the modification JSON item
				SysTime mtime;
				if (appConfig.getValueBool("monitor")) {
					// Use the newPath modified timestamp
					mtime = timeLastModified(newPath).toUTC();
				} else {
					// Use the current system time
					mtime = Clock.currTime().toUTC();
				}
								
				JSONValue data = [
					"name": JSONValue(baseName(newPath)),
					"parentReference": JSONValue([
						"id": parentItem.id
					]),
					"fileSystemInfo": JSONValue([
						"lastModifiedDateTime": mtime.toISOExtString()
					])
				];
				
				// Perform the move operation on OneDrive
				bool isMoveSuccess = false;
				JSONValue response;
				string eTag = oldItem.eTag;
				
				// Create a new API Instance for this thread and initialise it
				OneDriveApi movePathOnlineApiInstance;
				movePathOnlineApiInstance = new OneDriveApi(appConfig);
				movePathOnlineApiInstance.initialise();
				
				// Try the online move
				for (int i = 0; i < 3; i++) {
					try {
						response = movePathOnlineApiInstance.updateById(oldItem.driveId, oldItem.id, data, eTag);
						isMoveSuccess = true;
						break;
					} catch (OneDriveException e) {
						// Handle a 412 - A precondition provided in the request (such as an if-match header) does not match the resource's current state.
						if (e.httpStatusCode == 412) {
							// OneDrive threw a 412 error, most likely: ETag does not match current item's value
							// Retry without eTag
							if (debugLogging) {addLogEntry("File Move Failed - OneDrive eTag / cTag match issue", ["debug"]);}
							if (verboseLogging) {addLogEntry("OneDrive returned a 'HTTP 412 - Precondition Failed' when attempting to move the file - gracefully handling error", ["verbose"]);}
							eTag = null;
							// Retry to move the file but without the eTag, via the for() loop
						} else if (e.httpStatusCode == 409) {
							// Destination item already exists and is a conflict, delete existing item first
							addLogEntry("Moved local item will overwrite an existing online item - deleting old online item first");
							uploadDeletedItem(newItem, newPath);
						} else
							break;
					}
				} 
				
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				movePathOnlineApiInstance.releaseCurlEngine();
				movePathOnlineApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				
				// save the move response from OneDrive in the database
				// Is the response a valid JSON object - validation checking done in saveItem
				saveItem(response);
			}
		} else {
			// Moved item is unwanted
			addLogEntry("Item has been moved to a location that is excluded from sync operations. Removing item from OneDrive");
			uploadDeletedItem(oldItem, oldPath);
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Perform integrity validation of the file that was uploaded
	bool performUploadIntegrityValidationChecks(JSONValue uploadResponse, string localFilePath, long localFileSize) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		bool integrityValid = false;
	
		if (!disableUploadValidation) {
			// Integrity validation has not been disabled (this is the default so we are always integrity checking our uploads)
			if (uploadResponse.type() == JSONType.object) {
				// Provided JSON is a valid JSON
				long uploadFileSize;
				string uploadFileHash;
				string localFileHash;
				// Regardless if valid JSON is responded with, 'size' and 'quickXorHash' must be present
				if (hasFileSize(uploadResponse) && hasQuickXorHash(uploadResponse)) {
					uploadFileSize = uploadResponse["size"].integer;
					uploadFileHash = uploadResponse["file"]["hashes"]["quickXorHash"].str;
					localFileHash = computeQuickXorHash(localFilePath);
				} else {
					if (verboseLogging) {
						addLogEntry("Online file validation unable to be performed: input JSON whilst valid did not contain data which could be validated", ["verbose"]);
						addLogEntry("WARNING: Skipping upload integrity check for: " ~ localFilePath, ["verbose"]);
					}
					return integrityValid;
				}
				
				// compare values
				if ((localFileSize == uploadFileSize) && (localFileHash == uploadFileHash)) {
					// Uploaded file integrity intact
					if (debugLogging) {addLogEntry("Uploaded local file matches reported online size and hash values", ["debug"]);}
					// set to true and return
					integrityValid = true;
					return integrityValid;
				} else {
					// Upload integrity failure .. what failed?
					// There are 2 scenarios where this happens:
					// 1. Failed Transfer
					// 2. Upload file is going to a SharePoint Site, where Microsoft enriches the file with additional metadata with no way to disable
					addLogEntry("WARNING: Online file integrity failure for: " ~ localFilePath, ["info", "notify"]);
					
					// What integrity failed - size?
					if (localFileSize != uploadFileSize) {
						if (verboseLogging) {addLogEntry("WARNING: Online file integrity failure - Size Mismatch", ["verbose"]);}
					}
					
					// What integrity failed - hash?
					if (localFileHash != uploadFileHash) {
						if (verboseLogging) {addLogEntry("WARNING: Online file integrity failure - Hash Mismatch", ["verbose"]);}
					}
					
					// What account type is this?
					if (appConfig.accountType != "personal") {
						// Not a personal account, thus the integrity failure is most likely due to SharePoint
						if (verboseLogging) {
							addLogEntry("CAUTION: When you upload files to Microsoft OneDrive that uses SharePoint as its backend, Microsoft OneDrive will alter your files post upload.", ["verbose"]);
							addLogEntry("CAUTION: This will lead to technical differences between the version stored online and your local original file, potentially causing issues with the accuracy or consistency of your data.", ["verbose"]);
							addLogEntry("CAUTION: Please refer to https://github.com/OneDrive/onedrive-api-docs/issues/935 for further details.", ["verbose"]);
						}
					}
					// How can this be disabled?
					addLogEntry("To disable the integrity checking of uploaded files use --disable-upload-validation");
				}
			} else {
				if (verboseLogging) {
					addLogEntry("Online file validation unable to be performed: input JSON whilst valid did not contain data which could be validated", ["verbose"]);
					addLogEntry("WARNING: Skipping upload integrity check for: " ~ localFilePath, ["verbose"]);
				}
			}
		} else {
			// Skipping upload integrity check, do not notify the user via the GUI ... they have explicitly disabled upload validation
			if (verboseLogging) {addLogEntry("WARNING: Skipping upload integrity check for: " ~ localFilePath, ["verbose"]);}
			
			// We are bypassing integrity checks due to --disable-upload-validation
			if (debugLogging) {
				addLogEntry("Online file validation disabled due to --disable-upload-validation", ["debug"]);
				addLogEntry("- Assuming file integrity is OK and valid", ["debug"]);
			}
			
			// Ensure we return 'true', but this is in a false sense, as we are skipping the integrity check, so we assume the file is good
			integrityValid = true;
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// Is the file integrity online valid?
		return integrityValid;
	}
	
	// Query Office 365 SharePoint Shared Library site name to obtain it's Drive ID
	void querySiteCollectionForDriveID(string sharepointLibraryNameToQuery) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Steps to get the ID:
		// 1. Query https://graph.microsoft.com/v1.0/sites?search= with the name entered
		// 2. Evaluate the response. A valid response will contain the description and the id. If the response comes back with nothing, the site name cannot be found or no access
		// 3. If valid, use the returned ID and query the site drives
		//		https://graph.microsoft.com/v1.0/sites/<site_id>/drives
		// 4. Display Shared Library Name & Drive ID
		
		string site_id;
		string drive_id;
		bool found = false;
		JSONValue siteQuery;
		string nextLink;
		string[] siteSearchResults;
		
		// Create a new API Instance for this thread and initialise it
		OneDriveApi querySharePointLibraryNameApiInstance;
		querySharePointLibraryNameApiInstance = new OneDriveApi(appConfig);
		querySharePointLibraryNameApiInstance.initialise();
		
		// The account type must not be a personal account type
		if (appConfig.accountType == "personal") {
			addLogEntry("ERROR: A OneDrive Personal Account cannot be used with --get-sharepoint-drive-id. Please re-authenticate your client using a OneDrive Business Account.");
			return;
		}
		
		// What query are we performing?
		addLogEntry();
		addLogEntry("Office 365 Library Name Query: " ~ sharepointLibraryNameToQuery);
		
		while (true) {
			// Check if exitHandlerTriggered is true
			if (exitHandlerTriggered) {
				// break out of the 'while (true)' loop
				break;
			}
		
			try {
				siteQuery = querySharePointLibraryNameApiInstance.o365SiteSearch(nextLink);
			} catch (OneDriveException e) {
				addLogEntry("ERROR: Query of OneDrive for Office 365 Library Name failed");
				// Forbidden - most likely authentication scope needs to be updated
				if (e.httpStatusCode == 403) {
					addLogEntry("ERROR: Authentication scope needs to be updated. Use --reauth and re-authenticate client.");
					
					// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
					querySharePointLibraryNameApiInstance.releaseCurlEngine();
					querySharePointLibraryNameApiInstance = null;
					// Perform Garbage Collection
					GC.collect();
					return;
				}
				
				// Requested resource cannot be found
				if (e.httpStatusCode == 404) {
					string siteSearchUrl;
					if (nextLink.empty) {
						siteSearchUrl = querySharePointLibraryNameApiInstance.getSiteSearchUrl();
					} else {
						siteSearchUrl = nextLink;
					}
					// log the error
					addLogEntry("ERROR: Your OneDrive Account and Authentication Scope cannot access this OneDrive API: " ~ siteSearchUrl);
					addLogEntry("ERROR: To resolve, please discuss this issue with whomever supports your OneDrive and SharePoint environment.");
					
					// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
					querySharePointLibraryNameApiInstance.releaseCurlEngine();
					querySharePointLibraryNameApiInstance = null;
					// Perform Garbage Collection
					GC.collect();
					return;
				}
				
				// Default operation if not 408,429,503,504 errors
				// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
				// Display what the error is
				displayOneDriveErrorMessage(e.msg, thisFunctionName);
				
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				querySharePointLibraryNameApiInstance.releaseCurlEngine();
				querySharePointLibraryNameApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				return;
			}
			
			// is siteQuery a valid JSON object & contain data we can use?
			if ((siteQuery.type() == JSONType.object) && ("value" in siteQuery)) {
				// valid JSON object
				if (debugLogging) {addLogEntry("O365 Query Response: " ~ to!string(siteQuery), ["debug"]);}
				
				foreach (searchResult; siteQuery["value"].array) {
					// Need an 'exclusive' match here with sharepointLibraryNameToQuery as entered
					if (debugLogging) {addLogEntry("Found O365 Site: " ~ to!string(searchResult), ["debug"]);}
					
					// 'displayName' and 'id' have to be present in the search result record in order to query the site
					if (("displayName" in searchResult) && ("id" in searchResult)) {
						if (sharepointLibraryNameToQuery == searchResult["displayName"].str){
							// 'displayName' matches search request
							site_id = searchResult["id"].str;
							JSONValue siteDriveQuery;
							string nextLinkDrive;

							while (true) {
								try {
									siteDriveQuery = querySharePointLibraryNameApiInstance.o365SiteDrives(site_id, nextLinkDrive);
								} catch (OneDriveException e) {
									addLogEntry("ERROR: Query of OneDrive for Office Site ID failed");
									// display what the error is
									displayOneDriveErrorMessage(e.msg, thisFunctionName);
									
									// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
									querySharePointLibraryNameApiInstance.releaseCurlEngine();
									querySharePointLibraryNameApiInstance = null;
									// Perform Garbage Collection
									GC.collect();
									return;
								}
								
								// is siteDriveQuery a valid JSON object & contain data we can use?
								if ((siteDriveQuery.type() == JSONType.object) && ("value" in siteDriveQuery)) {
									// valid JSON object
									foreach (driveResult; siteDriveQuery["value"].array) {
										// Display results
										found = true;
										addLogEntry("-----------------------------------------------");
										if (debugLogging) {addLogEntry("Site Details: " ~ to!string(driveResult), ["debug"]);}
										addLogEntry("Site Name:    " ~ searchResult["displayName"].str);
										addLogEntry("Library Name: " ~ driveResult["name"].str);
										addLogEntry("drive_id:     " ~ driveResult["id"].str);
										addLogEntry("Library URL:  " ~ driveResult["webUrl"].str);
									}
			
									// If a collection exceeds the default page size (200 items), the @odata.nextLink property is returned in the response 
									// to indicate more items are available and provide the request URL for the next page of items.
									if ("@odata.nextLink" in siteDriveQuery) {
										// Update nextLink to next set of SharePoint library names
										nextLinkDrive = siteDriveQuery["@odata.nextLink"].str;
										if (debugLogging) {addLogEntry("Setting nextLinkDrive to (@odata.nextLink): " ~ nextLinkDrive, ["debug"]);}

										// Sleep for a while to avoid busy-waiting
										Thread.sleep(dur!"msecs"(100)); // Adjust the sleep duration as needed
									} else {
										// closeout
										addLogEntry("-----------------------------------------------");
										break;
									}
								} else {
									// not a valid JSON object
									addLogEntry("ERROR: There was an error performing this operation on Microsoft OneDrive");
									addLogEntry("ERROR: Increase logging verbosity to assist determining why.");
									
									// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
									querySharePointLibraryNameApiInstance.releaseCurlEngine();
									querySharePointLibraryNameApiInstance = null;
									// Perform Garbage Collection
									GC.collect();
									return;
								}
							}
						}
					} else {
						// 'displayName', 'id' or ''webUrl' not present in JSON results for a specific site
						string siteNameAvailable = "Site 'name' was restricted by OneDrive API permissions";
						bool displayNameAvailable = false;
						bool idAvailable = false;
						if ("name" in searchResult) siteNameAvailable = searchResult["name"].str;
						if ("displayName" in searchResult) displayNameAvailable = true;
						if ("id" in searchResult) idAvailable = true;
						
						// Display error details for this site data
						addLogEntry();
						addLogEntry("ERROR: SharePoint Site details not provided for: " ~ siteNameAvailable);
						addLogEntry("ERROR: The SharePoint Site results returned from OneDrive API do not contain the required items to match. Please check your permissions with your site administrator.");
						addLogEntry("ERROR: Your site security settings is preventing the following details from being accessed: 'displayName' or 'id'");
						if (verboseLogging) {
							addLogEntry(" - Is 'displayName' available = " ~ to!string(displayNameAvailable), ["verbose"]);
							addLogEntry(" - Is 'id' available          = " ~ to!string(idAvailable), ["verbose"]);
						}
						addLogEntry("ERROR: To debug this further, please increase application output verbosity to provide further insight as to what details are actually being returned.");
					}
				}
				
				if(!found) {
					// The SharePoint site we are searching for was not found in this bundle set
					// Add to siteSearchResults so we can display what we did find
					string siteSearchResultsEntry;
					foreach (searchResult; siteQuery["value"].array) {
						// We can only add the displayName if it is available
						if ("displayName" in searchResult) {
							// Use the displayName
							siteSearchResultsEntry = " * " ~ searchResult["displayName"].str;
							siteSearchResults ~= siteSearchResultsEntry;
						} else {
							// Add, but indicate displayName unavailable, use id
							if ("id" in searchResult) {
								siteSearchResultsEntry = " * " ~ "Unknown displayName (Data not provided by API), Site ID: " ~ searchResult["id"].str;
								siteSearchResults ~= siteSearchResultsEntry;
							} else {
								// displayName and id unavailable, display in debug log the entry
								if (debugLogging) {addLogEntry("Bad SharePoint Data for site: " ~ to!string(searchResult), ["debug"]);}
							}
						}
					}
				}
			} else {
				// not a valid JSON object
				addLogEntry("ERROR: There was an error performing this operation on Microsoft OneDrive");
				addLogEntry("ERROR: Increase logging verbosity to assist determining why.");
				
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				querySharePointLibraryNameApiInstance.releaseCurlEngine();
				querySharePointLibraryNameApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				return;
			}
			
			// If a collection exceeds the default page size (200 items), the @odata.nextLink property is returned in the response 
			// to indicate more items are available and provide the request URL for the next page of items.
			if ("@odata.nextLink" in siteQuery) {
				// Update nextLink to next set of SharePoint library names
				nextLink = siteQuery["@odata.nextLink"].str;
				if (debugLogging) {addLogEntry("Setting nextLink to (@odata.nextLink): " ~ nextLink, ["debug"]);}
			} else break;
			
			// Sleep for a while to avoid busy-waiting
			Thread.sleep(dur!"msecs"(100)); // Adjust the sleep duration as needed
		}
		
		// Was the intended target found?
		if(!found) {
			// Was the search a wildcard?
			if (sharepointLibraryNameToQuery != "*") {
				// Only print this out if the search was not a wildcard
				addLogEntry();
				addLogEntry("ERROR: The requested SharePoint site could not be found. Please check it's name and your permissions to access the site.");
			}
			// List all sites returned to assist user
			addLogEntry();
			addLogEntry("The following SharePoint site names were returned:");
			foreach (searchResultEntry; siteSearchResults) {
				// list the display name that we use to match against the user query
				addLogEntry(searchResultEntry);
			}
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		querySharePointLibraryNameApiInstance.releaseCurlEngine();
		querySharePointLibraryNameApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Query the sync status of the client and the local system
	void queryOneDriveForSyncStatus(string pathToQueryStatusOn) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// Query the account driveId and rootId to get the /delta JSON information
		// Process that JSON data for relevancy
		
		// Function variables
		long downloadSize = 0;
		string deltaLink = null;
		string driveIdToQuery = appConfig.defaultDriveId;
		string itemIdToQuery = appConfig.defaultRootId;
		JSONValue deltaChanges;
		
		// Array of JSON items
		JSONValue[] jsonItemsArray;
		
		// Query Database for a potential deltaLink starting point
		deltaLink = itemDB.getDeltaLink(driveIdToQuery, itemIdToQuery);
		
		// Log what we are doing
		addProcessingLogHeaderEntry("Querying the change status of Drive ID: " ~ driveIdToQuery, appConfig.verbosityCount);
		
		// Create a new API Instance for querying the actual /delta and initialise it
		OneDriveApi getDeltaDataOneDriveApiInstance;
		getDeltaDataOneDriveApiInstance = new OneDriveApi(appConfig);
		getDeltaDataOneDriveApiInstance.initialise();
		
		while (true) {
			// Check if exitHandlerTriggered is true
			if (exitHandlerTriggered) {
				// break out of the 'while (true)' loop
				break;
			}
			
			// Add a processing '.'
			if (appConfig.verbosityCount == 0) {
				addProcessingDotEntry();
			}
		
			// Get the /delta changes via the OneDrive API
			// getDeltaChangesByItemId has the re-try logic for transient errors
			deltaChanges = getDeltaChangesByItemId(driveIdToQuery, itemIdToQuery, deltaLink, getDeltaDataOneDriveApiInstance);
			
			// If the initial deltaChanges response is an invalid JSON object, keep trying until we get a valid response ..
			if (deltaChanges.type() != JSONType.object) {
				// While the response is not a JSON Object or the Exit Handler has not been triggered
				while (deltaChanges.type() != JSONType.object) {
					// Handle the invalid JSON response and retry
					if (debugLogging) {addLogEntry("ERROR: Query of the OneDrive API via deltaChanges = getDeltaChangesByItemId() returned an invalid JSON response", ["debug"]);}
					deltaChanges = getDeltaChangesByItemId(driveIdToQuery, itemIdToQuery, deltaLink, getDeltaDataOneDriveApiInstance);
				}
			}
			
			// We have a valid deltaChanges JSON array. This means we have at least 200+ JSON items to process.
			// The API response however cannot be run in parallel as the OneDrive API sends the JSON items in the order in which they must be processed
			foreach (onedriveJSONItem; deltaChanges["value"].array) {
				// is the JSON a root object - we dont want to count this
				if (!isItemRoot(onedriveJSONItem)) {
					// Files are the only item that we want to calculate
					if (isItemFile(onedriveJSONItem)) {
						// JSON item is a file
						// Is the item filtered out due to client side filtering rules?
						if (!checkJSONAgainstClientSideFiltering(onedriveJSONItem)) {
							// Is the path of this JSON item 'in-scope' or 'out-of-scope' ?
							if (pathToQueryStatusOn != "/") {
								// We need to check the path of this item against pathToQueryStatusOn
								string thisItemPath = "";
								if (("path" in onedriveJSONItem["parentReference"]) != null) {
									// If there is a parent reference path, try and use it
									string selfBuiltPath = onedriveJSONItem["parentReference"]["path"].str ~ "/" ~ onedriveJSONItem["name"].str;
									
									// Check for ':' and split if present
									auto splitIndex = selfBuiltPath.indexOf(":");
									if (splitIndex != -1) {
										// Keep only the part after ':'
										selfBuiltPath = selfBuiltPath[splitIndex + 1 .. $];
									}
									
									// Set thisItemPath to the self built path
									thisItemPath = selfBuiltPath;
								} else {
									// no parent reference path available
									thisItemPath = onedriveJSONItem["name"].str;
								}
								// can we find 'pathToQueryStatusOn' in 'thisItemPath' ?
								if (canFind(thisItemPath, pathToQueryStatusOn)) {
									// Add this to the array for processing
									jsonItemsArray ~= onedriveJSONItem;
								}
							} else {
								// We are not doing a --single-directory check
								// Add this to the array for processing
								jsonItemsArray ~= onedriveJSONItem;
							}
						}
					}
				}
			}
			
			// The response may contain either @odata.deltaLink or @odata.nextLink
			if ("@odata.deltaLink" in deltaChanges) {
				deltaLink = deltaChanges["@odata.deltaLink"].str;
				if (debugLogging) {addLogEntry("Setting next deltaLink to (@odata.deltaLink): " ~ deltaLink, ["debug"]);}
			}
			
			// Update deltaLink to next changeSet bundle
			if ("@odata.nextLink" in deltaChanges) {	
				deltaLink = deltaChanges["@odata.nextLink"].str;
				if (debugLogging) {addLogEntry("Setting next deltaLink to (@odata.nextLink): " ~ deltaLink, ["debug"]);}
			} else break;
			
			// Sleep for a while to avoid busy-waiting
			Thread.sleep(dur!"msecs"(100)); // Adjust the sleep duration as needed
		}
		
		// Terminate getDeltaDataOneDriveApiInstance here
		getDeltaDataOneDriveApiInstance.releaseCurlEngine();
		getDeltaDataOneDriveApiInstance = null;
		// Perform Garbage Collection on this destroyed curl engine
		GC.collect();
		
		// Needed after printing out '....' when fetching changes from OneDrive API
		if (appConfig.verbosityCount == 0) {
			completeProcessingDots();
		}
		
		// Are there any JSON items to process?
		if (count(jsonItemsArray) != 0) {
			// There are items to process
			foreach (onedriveJSONItem; jsonItemsArray.array) {
			
				// variables we need
				string thisItemParentDriveId;
				string thisItemId;
				string thisItemHash;
				bool existingDBEntry = false;
				
				// Is this file a remote item (on a shared folder) ?
				if (isItemRemote(onedriveJSONItem)) {
					// remote drive item
					thisItemParentDriveId = onedriveJSONItem["remoteItem"]["parentReference"]["driveId"].str;
					thisItemId = onedriveJSONItem["id"].str;
				} else {
					// standard drive item
					thisItemParentDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
					thisItemId = onedriveJSONItem["id"].str;
				}
				
				// Get the file hash
				if (hasHashes(onedriveJSONItem)) {
					// At a minimum we require 'quickXorHash' to exist
					if (hasQuickXorHash(onedriveJSONItem)) {
						// JSON item has a hash we can use
						thisItemHash = onedriveJSONItem["file"]["hashes"]["quickXorHash"].str;
					}
					
					// Check if the item has been seen before
					Item existingDatabaseItem;
					existingDBEntry = itemDB.selectById(thisItemParentDriveId, thisItemId, existingDatabaseItem);
					
					if (existingDBEntry) {
						// item exists in database .. do the database details match the JSON record?
						if (existingDatabaseItem.quickXorHash != thisItemHash) {
							// file hash is different, this will trigger a download event
							if (hasFileSize(onedriveJSONItem)) {
								downloadSize = downloadSize + onedriveJSONItem["size"].integer;
							}
						} 
					} else {
						// item does not exist in the database
						// this item has already passed client side filtering rules (skip_dir, skip_file, sync_list)
						// this will trigger a download event
						if (hasFileSize(onedriveJSONItem)) {
							downloadSize = downloadSize + onedriveJSONItem["size"].integer;
						}
					}
				}
			}
		}
			
		// Was anything detected that would constitute a download?
		if (downloadSize > 0) {
			// we have something to download
			if (pathToQueryStatusOn != "/") {
				addLogEntry("The selected local directory via --single-directory is out of sync with Microsoft OneDrive");
			} else {
				addLogEntry("The configured local 'sync_dir' directory is out of sync with Microsoft OneDrive");
			}
			addLogEntry("Approximate data to download from Microsoft OneDrive: " ~ to!string(downloadSize/1024) ~ " KB");
		} else {
			// No changes were returned
			addLogEntry("There are no pending changes from Microsoft OneDrive; your local directory matches the data online.");
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Query OneDrive for file details of a given path, returning either the 'webURL' or 'lastModifiedBy' JSON facet
	void queryOneDriveForFileDetails(string inputFilePath, string runtimePath, string outputType) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		OneDriveApi queryOneDriveForFileDetailsApiInstance;
		
		// Calculate the full local file path
		string fullLocalFilePath = buildNormalizedPath(buildPath(runtimePath, inputFilePath));
		
		// Query if file is valid locally
		if (exists(fullLocalFilePath)) {
			// search drive_id list
			string[] distinctDriveIds = itemDB.selectDistinctDriveIds();
			bool pathInDB = false;
			Item dbItem;
			
			foreach (searchDriveId; distinctDriveIds) {
				// Does this path exist in the database, use the 'inputFilePath'
				if (itemDB.selectByPath(inputFilePath, searchDriveId, dbItem)) {
					// item is in the database
					pathInDB = true;
					JSONValue fileDetailsFromOneDrive;
				
					// Create a new API Instance for this thread and initialise it
					queryOneDriveForFileDetailsApiInstance = new OneDriveApi(appConfig);
					queryOneDriveForFileDetailsApiInstance.initialise();
					
					try {
						fileDetailsFromOneDrive = queryOneDriveForFileDetailsApiInstance.getPathDetailsById(dbItem.driveId, dbItem.id);
						// Dont cleanup here as if we are creating a shareable file link (below) it is still needed
						
					} catch (OneDriveException exception) {
						// display what the error is
						displayOneDriveErrorMessage(exception.msg, thisFunctionName);
						
						// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
						queryOneDriveForFileDetailsApiInstance.releaseCurlEngine();
						queryOneDriveForFileDetailsApiInstance = null;
						// Perform Garbage Collection
						GC.collect();
						return;
					}
					
					// Is the API response a valid JSON file?
					if (fileDetailsFromOneDrive.type() == JSONType.object) {
					
						// debug output of response
						if (debugLogging) {addLogEntry("API Response: " ~ to!string(fileDetailsFromOneDrive), ["debug"]);}
						
						// What sort of response to we generate
						// --get-file-link response
						if (outputType == "URL") {
							if ((fileDetailsFromOneDrive.type() == JSONType.object) && ("webUrl" in fileDetailsFromOneDrive)) {
								// Valid JSON object
								addLogEntry();
								writeln("WebURL: ", fileDetailsFromOneDrive["webUrl"].str);
							}
						}
						
						// --modified-by response
						if (outputType == "ModifiedBy") {
							if ((fileDetailsFromOneDrive.type() == JSONType.object) && ("lastModifiedBy" in fileDetailsFromOneDrive)) {
								// Valid JSON object
								writeln();
								writeln("Last modified:    ", fileDetailsFromOneDrive["lastModifiedDateTime"].str);
								writeln("Last modified by: ", fileDetailsFromOneDrive["lastModifiedBy"]["user"]["displayName"].str);
								// if 'email' provided, add this to the output
								if ("email" in fileDetailsFromOneDrive["lastModifiedBy"]["user"]) {
									writeln("Email Address:    ", fileDetailsFromOneDrive["lastModifiedBy"]["user"]["email"].str);
								}
							}
						}
						
						// --create-share-link response
						if (outputType == "ShareableLink") {
						
							JSONValue accessScope;
							JSONValue createShareableLinkResponse;
							string thisDriveId = fileDetailsFromOneDrive["parentReference"]["driveId"].str;
							string thisItemId = fileDetailsFromOneDrive["id"].str;
							string fileShareLink;
							bool writeablePermissions = appConfig.getValueBool("with_editing_perms");
							
							// What sort of shareable link is required?
							if (writeablePermissions) {
								// configure the read-write access scope
								accessScope = [
									"type": "edit",
									"scope": "anonymous"
								];
							} else {
								// configure the read-only access scope (default)
								accessScope = [
									"type": "view",
									"scope": "anonymous"
								];
							}
							// If a share-password was passed use it when creating the link 
							if (strip(appConfig.getValueString("share_password")) != "") {
                                                                accessScope["password"] = appConfig.getValueString("share_password");
                                                        }
							
							// Try and create the shareable file link
							try {
								createShareableLinkResponse = queryOneDriveForFileDetailsApiInstance.createShareableLink(thisDriveId, thisItemId, accessScope);
							} catch (OneDriveException exception) {
								// display what the error is
								displayOneDriveErrorMessage(exception.msg, thisFunctionName);
								return;
							}
							
							// Is the API response a valid JSON file?
							if ((createShareableLinkResponse.type() == JSONType.object) && ("link" in createShareableLinkResponse)) {
								// Extract the file share link from the JSON response
								fileShareLink = createShareableLinkResponse["link"]["webUrl"].str;
								writeln("File Shareable Link: ", fileShareLink);
								if (writeablePermissions) {
									writeln("Shareable Link has read-write permissions - use and provide with caution"); 
								}
							}
						}
					}
					
					// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
					queryOneDriveForFileDetailsApiInstance.releaseCurlEngine();
					queryOneDriveForFileDetailsApiInstance = null;
					// Perform Garbage Collection
					GC.collect();
				}
			}
			
			// was path found?
			if (!pathInDB) {
				// File has not been synced with OneDrive
				addLogEntry("Selected path has not been synced with Microsoft OneDrive: " ~ inputFilePath);
			}
		} else {
			// File does not exist locally
			addLogEntry("Selected path not found on local system: " ~ inputFilePath);
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Query OneDrive for the quota details
	void queryOneDriveForQuotaDetails() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// This function is similar to getRemainingFreeSpace() but is different in data being analysed and output method
		JSONValue currentDriveQuota;
		string driveId;
		OneDriveApi getCurrentDriveQuotaApiInstance;

		if (appConfig.getValueString("drive_id").length) {
			driveId = appConfig.getValueString("drive_id");
		} else {
			driveId = appConfig.defaultDriveId;
		}
		
		try {
			// Create a new OneDrive API instance
			getCurrentDriveQuotaApiInstance = new OneDriveApi(appConfig);
			getCurrentDriveQuotaApiInstance.initialise();
			if (debugLogging) {addLogEntry("Seeking available quota for this drive id: " ~ driveId, ["debug"]);}
			currentDriveQuota = getCurrentDriveQuotaApiInstance.getDriveQuota(driveId);
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			getCurrentDriveQuotaApiInstance.releaseCurlEngine();
			getCurrentDriveQuotaApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			
		} catch (OneDriveException e) {
			if (debugLogging) {addLogEntry("currentDriveQuota = onedrive.getDriveQuota(driveId) generated a OneDriveException", ["debug"]);}
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			getCurrentDriveQuotaApiInstance.releaseCurlEngine();
			getCurrentDriveQuotaApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
		}
		
		// validate that currentDriveQuota is a JSON value
		if (currentDriveQuota.type() == JSONType.object) {
			// was 'quota' in response?
			if ("quota" in currentDriveQuota) {
		
				// debug output of response
				if (debugLogging) {addLogEntry("currentDriveQuota: " ~ to!string(currentDriveQuota), ["debug"]);}
				
				// human readable output of response
				string deletedValue = "Not Provided";
				string remainingValue = "Not Provided";
				string stateValue = "Not Provided";
				string totalValue = "Not Provided";
				string usedValue = "Not Provided";
			
				// Update values
				if ("deleted" in currentDriveQuota["quota"]) {
					deletedValue = byteToGibiByte(currentDriveQuota["quota"]["deleted"].integer);
				}
				
				if ("remaining" in currentDriveQuota["quota"]) {
					remainingValue = byteToGibiByte(currentDriveQuota["quota"]["remaining"].integer);
				}
				
				if ("state" in currentDriveQuota["quota"]) {
					stateValue = currentDriveQuota["quota"]["state"].str;
				}
				
				if ("total" in currentDriveQuota["quota"]) {
					totalValue = byteToGibiByte(currentDriveQuota["quota"]["total"].integer);
				}
				
				if ("used" in currentDriveQuota["quota"]) {
					usedValue = byteToGibiByte(currentDriveQuota["quota"]["used"].integer);
				}
				
				writeln("Microsoft OneDrive quota information as reported for this Drive ID: ", driveId);
				writeln();
				writeln("Deleted:   ", deletedValue, " GB (", currentDriveQuota["quota"]["deleted"].integer, " bytes)");
				writeln("Remaining: ", remainingValue, " GB (", currentDriveQuota["quota"]["remaining"].integer, " bytes)");
				writeln("State:     ", stateValue);
				writeln("Total:     ", totalValue, " GB (", currentDriveQuota["quota"]["total"].integer, " bytes)");
				writeln("Used:      ", usedValue, " GB (", currentDriveQuota["quota"]["used"].integer, " bytes)");
				writeln();
			} else {
				writeln("Microsoft OneDrive quota information is being restricted for this Drive ID: ", driveId);
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Query the system for session_upload.* files
	bool checkForInterruptedSessionUploads() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		bool interruptedUploads = false;
		long interruptedUploadsCount;
		
		// Scan the filesystem for the files we are interested in, build up interruptedUploadsSessionFiles array
		foreach (sessionFile; dirEntries(appConfig.configDirName, "session_upload.*", SpanMode.shallow)) {
			// calculate the full path
			string tempPath = buildNormalizedPath(buildPath(appConfig.configDirName, sessionFile));
			// add to array
			interruptedUploadsSessionFiles ~= [tempPath];
		}
		
		// Count all 'session_upload' files in appConfig.configDirName
		interruptedUploadsCount = count(interruptedUploadsSessionFiles);
		if (interruptedUploadsCount != 0) {
			interruptedUploads = true;
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// return if there are interrupted uploads to process
		return interruptedUploads;
	}
	
	// Query the system for resume_download.* files
	bool checkForResumableDownloads() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		bool resumableDownloads = false;
		long resumableDownloadsCount;
		
		// Scan the filesystem for the files we are interested in, build up interruptedDownloadFiles array
		foreach (resumeDownloadFile; dirEntries(appConfig.configDirName, "resume_download.*", SpanMode.shallow)) {
			// calculate the full path
			string tempPath = buildNormalizedPath(buildPath(appConfig.configDirName, resumeDownloadFile));
			// add to array
			interruptedDownloadFiles ~= [tempPath];
		}
		
		// Count all 'resume_download' files in appConfig.configDirName
		resumableDownloadsCount = count(interruptedDownloadFiles);
		if (resumableDownloadsCount != 0) {
			resumableDownloads = true;
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// return if there are interrupted uploads to process
		return resumableDownloads;
	}
	
	// Clear any session_upload.* files
	void clearInterruptedSessionUploads() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// Scan the filesystem for the files we are interested in, build up interruptedUploadsSessionFiles array
		foreach (sessionFile; dirEntries(appConfig.configDirName, "session_upload.*", SpanMode.shallow)) {
			// calculate the full path
			string tempPath = buildNormalizedPath(buildPath(appConfig.configDirName, sessionFile));
			JSONValue sessionFileData = readText(tempPath).parseJSON();
			addLogEntry("Removing interrupted session upload file due to --resync for: " ~ sessionFileData["localPath"].str, ["info"]);
			
			// Process removal
			if (!dryRun) {
				safeRemove(tempPath);
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Clear any resume_download.* files
	void clearInterruptedDownloads() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// Scan the filesystem for the files we are interested in, build up interruptedDownloadFiles array
		foreach (resumeDownloadFile; dirEntries(appConfig.configDirName, "resume_download.*", SpanMode.shallow)) {
			// calculate the full path
			string tempPath = buildNormalizedPath(buildPath(appConfig.configDirName, resumeDownloadFile));
			
			
			JSONValue resumeFileData = readText(tempPath).parseJSON();
			addLogEntry("Removing interrupted download file due to --resync for: " ~ resumeFileData["originalFilename"].str, ["info"]);
			string resumeFilename = resumeFileData["downloadFilename"].str;
			
			// Process removal
			if (!dryRun) {
				// remove the .partial file
				safeRemove(resumeFilename);
				// remove the resume_download. file
				safeRemove(tempPath);
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Process interrupted 'session_upload' files
	void processInterruptedSessionUploads() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// For each upload_session file that has been found, process the data to ensure it is still valid
		foreach (sessionFilePath; interruptedUploadsSessionFiles) {
			// What session data are we trying to restore
			if (verboseLogging) {addLogEntry("Attempting to restore file upload session using this session data file: " ~ sessionFilePath, ["verbose"]);}
			// Does this pass validation?
			if (!validateUploadSessionFileData(sessionFilePath)) {
				// Remove upload_session file as it is invalid
				// upload_session file contains an error - cant resume this session
				if (verboseLogging) {addLogEntry("Restore file upload session failed - cleaning up resumable session data file: " ~ sessionFilePath, ["verbose"]);}
				
				// cleanup session path
				if (exists(sessionFilePath)) {
					if (!dryRun) {
						remove(sessionFilePath);
					}
				}
			}
		}
		
		// At this point we should have an array of JSON items to resume uploading
		if (count(jsonItemsToResumeUpload) > 0) {
			// there are valid items to resume upload
			// Lets deal with all the JSON items that need to be resumed for upload in a batch process
			size_t batchSize = to!int(appConfig.getValueLong("threads"));
			long batchCount = (jsonItemsToResumeUpload.length + batchSize - 1) / batchSize;
			long batchesProcessed = 0;
			
			foreach (chunk; jsonItemsToResumeUpload.chunks(batchSize)) {
				// send an array containing 'appConfig.getValueLong("threads")' JSON items to resume upload
				resumeSessionUploadsInParallel(chunk);
			}
			
			// For this set of items, perform a DB PASSIVE checkpoint
			itemDB.performCheckpoint("PASSIVE");
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Process 'resumable download' files that were found
	void processResumableDownloadFiles() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// For each 'resume_download' file that has been found, process the data to ensure it is still valid
		foreach (resumeDownloadFile; interruptedDownloadFiles) {
			// What 'resumable data' are we trying to resume
			if (verboseLogging) {addLogEntry("Attempting to resume file download using this 'resumable data' file: " ~ resumeDownloadFile, ["verbose"]);}
			// Does this pass validation?
			if (!validateResumableDownloadFileData(resumeDownloadFile)) {
				// Remove 'resume_download' file as it is invalid
				if (verboseLogging) {addLogEntry("Resume file download verification failed - cleaning up resumable download data file: " ~ resumeDownloadFile, ["verbose"]);}
				// Cleanup 'resume_download' file
				if (exists(resumeDownloadFile)) {
					if (!dryRun) {
						remove(resumeDownloadFile);
					}
				}
			}
		}
		
		// At this point we should have an array of JSON items to resume downloading
		if (count(jsonItemsToResumeDownload) > 0) {
			// There are valid items to resume download
			// Lets deal with all the JSON items that need to be resumed for download in a batch process
			size_t batchSize = to!int(appConfig.getValueLong("threads"));
			long batchCount = (jsonItemsToResumeDownload.length + batchSize - 1) / batchSize;
			long batchesProcessed = 0;
			
			foreach (chunk; jsonItemsToResumeDownload.chunks(batchSize)) {
				// send an array containing 'appConfig.getValueLong("threads")' JSON items to resume download
				resumeDownloadsInParallel(chunk);
			}
			
			// For this set of items, perform a DB PASSIVE checkpoint
			itemDB.performCheckpoint("PASSIVE");
		}
		
		// Cleanup all 'resume_download' files
		foreach (resumeDownloadFile; interruptedDownloadFiles) {
			safeRemove(resumeDownloadFile);
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// A resume session upload file needs to be valid to be used
	// This function validates this data
	bool validateUploadSessionFileData(string sessionFilePath) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Due to this function, we need to keep the return <bool value>; code, so that this function operates as efficiently as possible.
		// It is pointless having the entire code run through and performing additional needless checks where it is not required
		// Whilst this means some extra code / duplication in this function, it cannot be helped
		
		JSONValue sessionFileData;
		OneDriveApi validateUploadSessionFileDataApiInstance;

		// Try and read the text from the session file as a JSON array
		try {
			if (getSize(sessionFilePath) > 0) {
				// There is data to read in
				sessionFileData = readText(sessionFilePath).parseJSON();
			} else {
				// No data to read in - invalid file
				if (debugLogging) {addLogEntry("SESSION-RESUME: Invalid JSON file: " ~ sessionFilePath, ["debug"]);}
				
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
				
				// return session file is invalid
				return false;
			}
		} catch (JSONException e) {
			if (debugLogging) {addLogEntry("SESSION-RESUME: Invalid JSON data in: " ~ sessionFilePath, ["debug"]);}
			
			// Display function processing time if configured to do so
			if (appConfig.getValueBool("display_processing_time") && debugLogging) {
				// Combine module name & running Function
				displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
			}
			
			// return session file is invalid
			return false;
		}
		
		// Does the file we wish to resume uploading exist locally still?
		if ("localPath" in sessionFileData) {
			string sessionLocalFilePath = sessionFileData["localPath"].str;
			if (debugLogging) {addLogEntry("SESSION-RESUME: sessionLocalFilePath: " ~ sessionLocalFilePath, ["debug"]);}
			
			// Does the file exist?
			if (!exists(sessionLocalFilePath)) {
				if (verboseLogging) {addLogEntry("The local file to upload does not exist locally anymore", ["verbose"]);}
				
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
				
				// return session file is invalid
				return false;
			}
			
			// Can we read the file?
			if (!readLocalFile(sessionLocalFilePath)) {
				// filesystem error already returned if unable to read
				
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
				
				// return session file is invalid
				return false;
			}
			
		} else {
			if (debugLogging) {addLogEntry("SESSION-RESUME: No localPath data in: " ~ sessionFilePath, ["debug"]);}
			
			// Display function processing time if configured to do so
			if (appConfig.getValueBool("display_processing_time") && debugLogging) {
				// Combine module name & running Function
				displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
			}
			
			// return session file is invalid
			return false;
		}
		
		// Check the session data for expirationDateTime
		if ("expirationDateTime" in sessionFileData) {
			SysTime expiration;
			string expirationTimestamp;
			expirationTimestamp = strip(sessionFileData["expirationDateTime"].str);
			
			// is expirationTimestamp valid?
			if (isValidUTCDateTime(expirationTimestamp)) {
				// string is a valid timestamp
				expiration = SysTime.fromISOExtString(expirationTimestamp);
			} else {
				// invalid timestamp from JSON file
				addLogEntry("WARNING: Invalid timestamp provided by the Microsoft OneDrive API: " ~ expirationTimestamp);
				
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
				
				// return session file is invalid
				return false;
			}
			
			// valid timestamp
			if (expiration < Clock.currTime()) {
				if (verboseLogging) {addLogEntry("The upload session has expired for: " ~ sessionFilePath, ["verbose"]);}
				
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
				
				// return session file is invalid
				return false;
			}
		} else {
			if (debugLogging) {addLogEntry("SESSION-RESUME: No expirationDateTime data in: " ~ sessionFilePath, ["debug"]);}
			
			// Display function processing time if configured to do so
			if (appConfig.getValueBool("display_processing_time") && debugLogging) {
				// Combine module name & running Function
				displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
			}
			
			// return session file is invalid
			return false;
		}
		
		// Check the online upload status, using the uloadURL in sessionFileData
		if ("uploadUrl" in sessionFileData) {
			JSONValue response;
			
			try {
				// Create a new OneDrive API instance
				validateUploadSessionFileDataApiInstance = new OneDriveApi(appConfig);
				validateUploadSessionFileDataApiInstance.initialise();
				
				// Request upload status
				response = validateUploadSessionFileDataApiInstance.requestUploadStatus(sessionFileData["uploadUrl"].str);
				
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				validateUploadSessionFileDataApiInstance.releaseCurlEngine();
				validateUploadSessionFileDataApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				
				// no error .. potentially all still valid
				
			} catch (OneDriveException e) {
				// handle any onedrive error response as invalid
				if (debugLogging) {addLogEntry("SESSION-RESUME: Invalid response when using uploadUrl in: " ~ sessionFilePath, ["debug"]);}
				
				// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
				validateUploadSessionFileDataApiInstance.releaseCurlEngine();
				validateUploadSessionFileDataApiInstance = null;
				// Perform Garbage Collection
				GC.collect();
				
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
				
				// return session file is invalid
				return false;				
			}
			
			// Do we have a valid response from OneDrive?
			if (response.type() == JSONType.object) {
				// Valid JSON object was returned
				if (("expirationDateTime" in response) && ("nextExpectedRanges" in response)) {
					// The 'uploadUrl' is valid, and the response contains elements we need
					sessionFileData["expirationDateTime"] = response["expirationDateTime"];
					sessionFileData["nextExpectedRanges"] = response["nextExpectedRanges"];
					
					if (sessionFileData["nextExpectedRanges"].array.length == 0) {
						if (verboseLogging) {addLogEntry("The upload session was already completed", ["verbose"]);}
						
						// Display function processing time if configured to do so
						if (appConfig.getValueBool("display_processing_time") && debugLogging) {
							// Combine module name & running Function
							displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
						}
						
						// return session file is invalid
						return false;
					}
				} else {
					if (debugLogging) {addLogEntry("SESSION-RESUME: No expirationDateTime & nextExpectedRanges data in Microsoft OneDrive API response: " ~ to!string(response), ["debug"]);}
					
					// Display function processing time if configured to do so
					if (appConfig.getValueBool("display_processing_time") && debugLogging) {
						// Combine module name & running Function
						displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
					}
					
					// return session file is invalid
					return false;
				}
			} else {
				// not a JSON object
				if (verboseLogging) {addLogEntry("Restore file upload session failed - invalid response from Microsoft OneDrive", ["verbose"]);}
				
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
				
				// return session file is invalid
				return false;
			}
		} else {
			if (debugLogging) {addLogEntry("SESSION-RESUME: No uploadUrl data in: " ~ sessionFilePath, ["debug"]);}
			
			// Display function processing time if configured to do so
			if (appConfig.getValueBool("display_processing_time") && debugLogging) {
				// Combine module name & running Function
				displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
			}
			
			// return session file is invalid
			return false;
		}
		
		// Add 'sessionFilePath' to 'sessionFileData' so that it can be used when we reuse the JSON data to resume the upload
		sessionFileData["sessionFilePath"] = sessionFilePath;
		
		// Add sessionFileData to jsonItemsToResumeUpload as it is now valid
		jsonItemsToResumeUpload ~= sessionFileData;
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// return session file is valid
		return true;
	}
	
	// A 'resumable download' file needs to be valid to be used
	bool validateResumableDownloadFileData(string resumeDownloadFile) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Function variables
		JSONValue resumeDownloadFileData;
		JSONValue latestOnlineFileDetails;
		OneDriveApi validateResumableDownloadFileDataApiInstance;
		string driveId;
		string itemId;
		string existingHash;
		string downloadFilename;
		long resumeOffset;
		string OneDriveFileXORHash;
		string OneDriveFileSHA256Hash;
		
		// Try and read the text from the 'resumable download' file as a JSON array
		try {
			if (getSize(resumeDownloadFile) > 0) {
				// There is data to read in
				resumeDownloadFileData = readText(resumeDownloadFile).parseJSON();
			} else {
				// No data to read in - invalid file
				if (debugLogging) {addLogEntry("SESSION-RESUME: Invalid JSON file: " ~ resumeDownloadFile, ["debug"]);}
				
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
				
				// Return 'resumable download' file is invalid
				return false;
			}
		} catch (JSONException e) {
			if (debugLogging) {addLogEntry("SESSION-RESUME: Invalid JSON data in: " ~ resumeDownloadFile, ["debug"]);}
			
			// Display function processing time if configured to do so
			if (appConfig.getValueBool("display_processing_time") && debugLogging) {
				// Combine module name & running Function
				displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
			}
			
			// Return 'resumable download' file is invalid
			return false;
		}
		
		// What needs to be checked?
		// - JSON has 'downloadFilename' - critical to check the online state
		// - JSON has 'driveId' - critical to check the online state
		// - JSON has 'itemId'  - critical to check the online state
		// - JSON has 'resumeOffset' - critical to check the online state
		// - JSON has 'onlineHash' with an applicable hash value - critical to check the online state
		
		if (!hasDownloadFilename(resumeDownloadFileData)) {
			// no downloadFilename present - file invalid
			if (verboseLogging) {addLogEntry("The 'resumable download' file contains invalid data: Missing 'downloadFilename'", ["verbose"]);}
			// Return 'resumable download' file is invalid
			return false;
		} else {
			// Configure search variables
			downloadFilename = resumeDownloadFileData["downloadFilename"].str;
			// Does the file specified by 'downloadFilename' exist on disk?
			if (!exists(downloadFilename)) {
				// File that is supposed to contain our resumable 
				if (verboseLogging) {addLogEntry("The 'resumable download' file no longer exists on your local disk: " ~ downloadFilename, ["verbose"]);}
				// Return 'resumable download' file is invalid
				return false;
			}
		}
		
		// If we get to this point 'downloadFilename' has a file name and the file exists on disk.
		// If any of the other validations fail, we can remove the file
		
		if (!hasDriveId(resumeDownloadFileData)) {
			// no driveId present - file invalid
			if (verboseLogging) {addLogEntry("The 'resumable download' file contains invalid data: Missing 'driveId'", ["verbose"]);}
			// Remove local file
			safeRemove(downloadFilename);
			// Return 'resumable download' file is invalid
			return false;
		} else {
			// Configure search variables
			driveId = resumeDownloadFileData["driveId"].str;
		}
		
		if (!hasItemId(resumeDownloadFileData)) {
			// no itemId present - file invalid
			if (verboseLogging) {addLogEntry("The 'resumable download' file contains invalid data: Missing 'itemId'", ["verbose"]);}
			// Remove local file
			safeRemove(downloadFilename);
			// Return 'resumable download' file is invalid
			return false;
		} else {
			// Configure search variables
			itemId = resumeDownloadFileData["itemId"].str;
		}
		
		if (!hasResumeOffset(resumeDownloadFileData)) {
			// no resumeOffset present - file invalid
			if (verboseLogging) {addLogEntry("The 'resumable download' file contains invalid data: Missing 'resumeOffset'", ["verbose"]);}
			// Remove local file
			safeRemove(downloadFilename);
			// Return 'resumable download' file is invalid
			return false;
		} else {
			// we have a resumeOffset value
			resumeOffset = to!long(resumeDownloadFileData["resumeOffset"].str);
			// We need to check 'resumeOffset' against the 'downloadFilename' on-disk size
			long onDiskSize = getSize(downloadFilename);
			
			if (resumeOffset != onDiskSize) {
				// The size of the offset location does not equal the size on disk .. if we resume that file, the file will be corrupt
				string logMessage = format("The 'resumable download' file on disk is a different size to the resumable offset: %s vs %s", to!string(resumeOffset), to!string(onDiskSize));
				if (verboseLogging) {addLogEntry(logMessage, ["verbose"]);}
				// Remove local file
				safeRemove(downloadFilename);
				// Return 'resumable download' file is invalid
				return false;
			}
		}
		
		if (!hasOnlineHash(resumeDownloadFileData)) {
			// no onlineHash present - file invalid
			if (verboseLogging) {addLogEntry("The 'resumable download' file contains invalid data: Missing 'onlineHash'", ["verbose"]);}
			// Remove local file
			safeRemove(downloadFilename);
			// Return 'resumable download' file is invalid
			return false;
		} else {
			// Configure hash variable from the resume data
			// QuickXorHash Check
			if (hasQuickXorHashResume(resumeDownloadFileData)) {
				// We have a quickXorHash value
				existingHash = resumeDownloadFileData["onlineHash"]["quickXorHash"].str;
			} else {
				// Fallback: Check for SHA256Hash
				if (hasSHA256HashResume(resumeDownloadFileData)) {
					// We have a sha256Hash value
					existingHash = resumeDownloadFileData["onlineHash"]["sha256Hash"].str;
				}
			}
			
			// At this point if we do not have a existingHash value, its a fail
			if (existingHash.empty) {
				if (verboseLogging) {addLogEntry("The 'resumable download' file contains invalid data: Missing 'onlineHash' value", ["verbose"]);}
				// Remove local file
				safeRemove(downloadFilename);
				// Return 'resumable download' file is invalid
				return false;
			}
		}
				
		// At this point we have elements in the 'resumable download' JSON data that will allow is to check if the online file has been modified - if it has, resuming the download is pointless
		try {
			// Create a new OneDrive API instance
			validateResumableDownloadFileDataApiInstance = new OneDriveApi(appConfig);
			validateResumableDownloadFileDataApiInstance.initialise();
	
			// Request latest file details
			latestOnlineFileDetails = validateResumableDownloadFileDataApiInstance.getPathDetailsById(driveId, itemId);
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			validateResumableDownloadFileDataApiInstance.releaseCurlEngine();
			validateResumableDownloadFileDataApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			
			// no error .. potentially all still valid
		} catch (OneDriveException e) {
			// handle any onedrive error response as invalid
			
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			validateResumableDownloadFileDataApiInstance.releaseCurlEngine();
			validateResumableDownloadFileDataApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			
			// Display function processing time if configured to do so
			if (appConfig.getValueBool("display_processing_time") && debugLogging) {
				// Combine module name & running Function
				displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
			}
			
			// Return 'resumable download' file is invalid
			return false;
		}
		
		// Configure the hashes from the online data for comparison
		if (hasHashes(latestOnlineFileDetails)) {
			// File details returned hash details
			// QuickXorHash
			if (hasQuickXorHash(latestOnlineFileDetails)) {
				// Use the provided quickXorHash as reported by OneDrive
				if (latestOnlineFileDetails["file"]["hashes"]["quickXorHash"].str != "") {
					OneDriveFileXORHash = latestOnlineFileDetails["file"]["hashes"]["quickXorHash"].str;
				}
			} else {
				// Fallback: Check for SHA256Hash
				if (hasSHA256Hash(latestOnlineFileDetails)) {
					// Use the provided sha256Hash as reported by OneDrive
					if (latestOnlineFileDetails["file"]["hashes"]["sha256Hash"].str != "") {
						OneDriveFileSHA256Hash = latestOnlineFileDetails["file"]["hashes"]["sha256Hash"].str;
					}
				}
			}
		}
		
		// Last check - has the online file changed since we attempted to do the download that we are trying to resume?
		// Test 'existingHash' against the potential 2 online hashes for a match
		// As we dont know what type of hash 'existingHash' is, we have to test it against the 2 known online types
		bool hashesMatch = (existingHash == OneDriveFileXORHash) || (existingHash == OneDriveFileSHA256Hash);
		
		// Do the hashes match?
		if (!hashesMatch) {
			// Hashes do not match
			if (verboseLogging) {addLogEntry("The 'online file' has changed in content since the download was last attempted. Aborting this resumable download attempt.", ["verbose"]);}
			// Remove local file
			safeRemove(downloadFilename);
			// Return 'resumable download' file is invalid
			return false;	
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// Augment 'latestOnlineFileDetails' with our resume point
		latestOnlineFileDetails["resumeOffset"] = JSONValue(to!string(resumeOffset));
		
		// Add latestOnlineFileDetails to jsonItemsToResumeDownload as it is now valid
		jsonItemsToResumeDownload ~= latestOnlineFileDetails;
		
		// Return 'resumable download' file is valid
		return true;
	}
	
	// Resume all resumable session uploads in parallel
	void resumeSessionUploadsInParallel(JSONValue[] array) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// This function received an array of JSON items to resume upload, the number of elements based on appConfig.getValueLong("threads")
		foreach (i, jsonItemToResume; processPool.parallel(array)) {
			// Take each JSON item and resume upload using the JSON data
			JSONValue uploadResponse;
			OneDriveApi uploadFileOneDriveApiInstance;
			
			// Create a new API instance
			uploadFileOneDriveApiInstance = new OneDriveApi(appConfig);
			uploadFileOneDriveApiInstance.initialise();
			
			// Pull out data from this JSON element
			string threadUploadSessionFilePath = jsonItemToResume["sessionFilePath"].str;
			long thisFileSizeLocal = getSize(jsonItemToResume["localPath"].str);
			
			// Try to resume the session upload using the provided data
			try {
				uploadResponse = performSessionFileUpload(uploadFileOneDriveApiInstance, thisFileSizeLocal, jsonItemToResume, threadUploadSessionFilePath);
			} catch (OneDriveException exception) {
				writeln("CODING TO DO: Handle an exception when performing a resume session upload");	
			}
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			uploadFileOneDriveApiInstance.releaseCurlEngine();
			uploadFileOneDriveApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
						
			// Was the response from the OneDrive API a valid JSON item?
			if (uploadResponse.type() == JSONType.object) {
				// A valid JSON object was returned - session resumption upload successful
				
				// Are we in an --upload-only & --remove-source-files scenario?
				// Use actual config values as we are doing an upload session recovery
				if ((uploadOnly) && (localDeleteAfterUpload)) {
					// Perform the local file deletion
					removeLocalFilePostUpload(jsonItemToResume["localPath"].str);
					
					// as file is removed, we have nothing to add to the local database
					if (debugLogging) {addLogEntry("Skipping adding to database as --upload-only & --remove-source-files configured", ["debug"]);}
				} else {
					// Save JSON item in database
					saveItem(uploadResponse);
				}
			} else {
				// No valid response was returned
				addLogEntry("CODING TO DO: what to do when session upload resumption JSON data is not valid ... nothing ? error message ?");
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Resume all resumable downloads in parallel
	void resumeDownloadsInParallel(JSONValue[] array) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// This function received an array of JSON items to resume download, the number of elements based on appConfig.getValueLong("threads")
		foreach (i, jsonItemToResume; processPool.parallel(array)) {
			// Take each JSON item and resume download using the JSON data
			
			// Extract the 'offset' from the JSON data
			long resumeOffset;
			resumeOffset = to!long(jsonItemToResume["resumeOffset"].str);
			
			// Take each JSON item and download it using the offset
			downloadFileItem(jsonItemToResume, false, resumeOffset);
		}
	
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Function to process the path by removing prefix up to ':' - remove '/drive/root:' from a path string
	string processPathToRemoveRootReference(ref string pathToCheck) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		size_t colonIndex = pathToCheck.indexOf(":");
		if (colonIndex != -1) {
			if (debugLogging) {addLogEntry("Updating " ~ pathToCheck ~ " to remove prefix up to ':'", ["debug"]);}
			pathToCheck = pathToCheck[colonIndex + 1 .. $];
			if (debugLogging) {addLogEntry("Updated path: " ~ pathToCheck, ["debug"]);}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// return updated path
		return pathToCheck;
	}
	
	// Generate path from JSON data
	string generatePathFromJSONData(JSONValue onedriveJSONItem) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Function variables
		string parentPath;
		string combinedPath;
		string computedItemPath;
		bool parentInDatabase = false;
		
		// Set itemName
		string itemName = onedriveJSONItem["name"].str;
		// If this item is on our 'driveId' then use the following, otherwise we need to calculate parental path to display the 'correct' path
		string thisItemDriveId = onedriveJSONItem["parentReference"]["driveId"].str;
		string thisItemParentId = onedriveJSONItem["parentReference"]["id"].str;
		
		// Issue #3336 - Convert driveId to lowercase before any test
		if (appConfig.accountType == "personal") {
			thisItemDriveId = transformToLowerCase(thisItemDriveId);
		}
		
		if (thisItemDriveId == appConfig.defaultDriveId) {
			// As this is on our driveId, use the path details as is
			parentPath = onedriveJSONItem["parentReference"]["path"].str;
			combinedPath = buildNormalizedPath(buildPath(parentPath, itemName));
		} else {
			// As this is not our driveId, the 'path' reference above is the 'full' remote path, which is not reflective of our location'
			// Are the 'parent' details in the database?
			parentInDatabase = itemDB.idInLocalDatabase(thisItemDriveId, thisItemParentId);
			if (parentInDatabase) {
				// Parent in DB .. we can calculate path
				computedItemPath = computeItemPath(thisItemDriveId, thisItemParentId);
				combinedPath = buildNormalizedPath(buildPath(computedItemPath, itemName));
			} else {
				// We cant calculate this path
				parentPath = onedriveJSONItem["parentReference"]["name"].str;
				combinedPath = buildNormalizedPath(buildPath(parentPath, itemName));
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		return processPathToRemoveRootReference(combinedPath);
	}
	
	// Function to find a given DriveId in the onlineDriveDetails associative array that maps driveId to DriveDetailsCache
	// If 'true' will return 'driveDetails' containing the struct data 'DriveDetailsCache'
	bool canFindDriveId(string driveId, out DriveDetailsCache driveDetails) {
		
		// Not adding performance metrics to this function
	
		auto ptr = driveId in onlineDriveDetails;
		if (ptr !is null) {
			driveDetails = *ptr; // Dereference the pointer to get the value
			return true;
		} else {
			return false;
		}
	}
	
	// Add this driveId plus relevant details for future reference and use
	void addOrUpdateOneDriveOnlineDetails(string driveId) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}

		bool quotaRestricted;
		bool quotaAvailable;
		long quotaRemaining;
		
		// Get the data from online
		auto onlineDriveData = getRemainingFreeSpaceOnline(driveId);
		quotaRestricted = to!bool(onlineDriveData[0][0]);
		quotaAvailable = to!bool(onlineDriveData[0][1]);
		quotaRemaining = to!long(onlineDriveData[0][2]);
		onlineDriveDetails[driveId] = DriveDetailsCache(driveId, quotaRestricted, quotaAvailable, quotaRemaining);
		
		// Debug log what the cached array now contains
		if (debugLogging) {addLogEntry("onlineDriveDetails: " ~ to!string(onlineDriveDetails), ["debug"]);}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}

	// Return a specific 'driveId' details from 'onlineDriveDetails'
	DriveDetailsCache getDriveDetails(string driveId) {
		
		// Not adding performance metrics to this function
		
		auto ptr = driveId in onlineDriveDetails;
		if (ptr !is null) {
			return *ptr;  // Dereference the pointer to get the value
		} else {
			// Return a default DriveDetailsCache or handle the case where the driveId is not found
			return DriveDetailsCache.init; // Return default-initialised struct
		}
	}
	
	// Search a given Drive ID, Item ID and filename to see if this exists in the location specified
	JSONValue searchDriveItemForFile(string parentItemDriveId, string parentItemId, string fileToUpload) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		JSONValue onedriveJSONItem;
		string searchName = baseName(fileToUpload);
		JSONValue thisLevelChildren;
		string nextLink;
		
		// Create a new API Instance for this thread and initialise it
		OneDriveApi checkFileOneDriveApiInstance;
		checkFileOneDriveApiInstance = new OneDriveApi(appConfig);
		checkFileOneDriveApiInstance.initialise();
		
		while (true) {
			// Check if exitHandlerTriggered is true
			if (exitHandlerTriggered) {
				// break out of the 'while (true)' loop
				break;
			}
		
			// Try and query top level children
			try {
				thisLevelChildren = checkFileOneDriveApiInstance.listChildren(parentItemDriveId, parentItemId, nextLink);
			} catch (OneDriveException exception) {
				// OneDrive threw an error
				if (debugLogging) {
					addLogEntry(debugLogBreakType1, ["debug"]);
					addLogEntry("Query Error: thisLevelChildren = checkFileOneDriveApiInstance.listChildren(parentItemDriveId, parentItemId, nextLink)", ["debug"]);
					addLogEntry("driveId:   " ~ parentItemDriveId, ["debug"]);
					addLogEntry("idToQuery: " ~ parentItemId, ["debug"]);
					addLogEntry("nextLink:  " ~ nextLink, ["debug"]);
				}
				
				// Handle the 404 error code - the parent item id was not found on the drive id specified
				if (exception.httpStatusCode == 404) {
					// Return an empty JSON item, as parent item could not be found, thus any child object will never be found
					return onedriveJSONItem;
				} else {
					// Default operation if not 408,429,503,504 errors
					// - 408,429,503,504 errors are handled as a retry within oneDriveApiInstance
					// Display what the error is
					displayOneDriveErrorMessage(exception.msg, thisFunctionName);
				}
			}
			
			// 'thisLevelChildren' must be a valid JSON response to progress any further
			if (thisLevelChildren.type() == JSONType.object) {
				// Process thisLevelChildren response
				foreach (child; thisLevelChildren["value"].array) {
					// Only looking at files
					if ((child["name"].str == searchName) && (("file" in child) != null)) {
						// Found the matching file, return its JSON representation
						// Operations in this thread are done / complete
						
						// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
						checkFileOneDriveApiInstance.releaseCurlEngine();
						checkFileOneDriveApiInstance = null;
						// Perform Garbage Collection
						GC.collect();
						
						// Display function processing time if configured to do so
						if (appConfig.getValueBool("display_processing_time") && debugLogging) {
							// Combine module name & running Function
							displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
						}
						
						// Return child as found item
						return child;
					}
				}
				
				// If a collection exceeds the default page size (200 items), the @odata.nextLink property is returned in the response 
				// to indicate more items are available and provide the request URL for the next page of items.
				if ("@odata.nextLink" in thisLevelChildren) {
					// Update nextLink to next changeSet bundle
					if (debugLogging) {addLogEntry("Setting nextLink to (@odata.nextLink): " ~ nextLink, ["debug"]);}
					nextLink = thisLevelChildren["@odata.nextLink"].str;
				} else break;
				
				// Sleep for a while to avoid busy-waiting
				Thread.sleep(dur!"msecs"(100)); // Adjust the sleep duration as needed
			} else {
				// API response was not a valid response
				// Break out of the 'while (true)' loop
				break;
			}
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		checkFileOneDriveApiInstance.releaseCurlEngine();
		checkFileOneDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
					
		// return an empty JSON item, as search item was not found
		return onedriveJSONItem;
	}
	
	// Update 'onlineDriveDetails' with the latest data about this drive
	void updateDriveDetailsCache(string driveId, bool quotaRestricted, bool quotaAvailable, long localFileSize) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// As each thread is running differently, what is the current 'quotaRemaining' for 'driveId' ?
		long quotaRemaining;
		DriveDetailsCache cachedOnlineDriveData;
		cachedOnlineDriveData = getDriveDetails(driveId);
		quotaRemaining = cachedOnlineDriveData.quotaRemaining;
		
		// Update 'quotaRemaining'
		quotaRemaining = quotaRemaining - localFileSize;
		
		// Do the flags get updated?
		if (quotaRemaining <= 0) {
			if (appConfig.accountType == "personal"){
				// Issue #3336 - Convert driveId to lowercase before any test
				driveId = transformToLowerCase(driveId);
			
				if (driveId == appConfig.defaultDriveId) {
					// zero space available on our drive
					addLogEntry("ERROR: OneDrive account currently has zero space available. Please free up some space online or purchase additional capacity.");
					quotaRemaining = 0;
					quotaAvailable = false;
				}
			} else {
				// zero space available is being reported, maybe being restricted?
				if (verboseLogging) {addLogEntry("WARNING: OneDrive quota information is being restricted or providing a zero value. Please fix by speaking to your OneDrive / Office 365 Administrator.", ["verbose"]);}
				quotaRemaining = 0;
				quotaRestricted = true;
			}
		}
		
		// Updated the details
		onlineDriveDetails[driveId] = DriveDetailsCache(driveId, quotaRestricted, quotaAvailable, quotaRemaining);
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Update all of the known cached driveId quota details
	void freshenCachedDriveQuotaDetails() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		foreach (driveId; onlineDriveDetails.keys) {
			// Update this driveid quota details
			if (debugLogging) {addLogEntry("Freshen Quota Details for this driveId: " ~ driveId, ["debug"]);}
			addOrUpdateOneDriveOnlineDetails(driveId);
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Create a 'root' DB Tie Record for a Shared Folder from the JSON data
	void createDatabaseRootTieRecordForOnlineSharedFolder(JSONValue onedriveJSONItem, string relocatedFolderDriveId = null, string relocatedFolderParentId = null) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Creating|Updating a DB Tie
		if (debugLogging) {
			addLogEntry("Creating|Updating a 'root' DB Tie Record for this Shared Folder (Actual 'Shared With Me' Folder Name): " ~ onedriveJSONItem["name"].str, ["debug"]);
			addLogEntry("Raw JSON for 'root' DB Tie Record: " ~ to!string(onedriveJSONItem), ["debug"]);
		}

		// New DB Tie Item to detail the 'root' of the Shared Folder
		Item tieDBItem;
		string lastModifiedTimestamp;
		tieDBItem.name = "root";
		
		// Get the right parentReference details
		if (isItemRemote(onedriveJSONItem)) {
			tieDBItem.driveId = onedriveJSONItem["remoteItem"]["parentReference"]["driveId"].str;
			tieDBItem.id = onedriveJSONItem["remoteItem"]["id"].str;
		} else {
			if (onedriveJSONItem["name"].str != "root") {
				tieDBItem.driveId = onedriveJSONItem["parentReference"]["driveId"].str;
				
				// OneDrive Personal JSON responses are in-consistent with not having 'id' available
				if (hasParentReferenceId(onedriveJSONItem)) {
					// Use the parent reference id
					tieDBItem.id = onedriveJSONItem["parentReference"]["id"].str;
				} else {
					// Testing evidence shows that for Personal accounts, use the 'id' itself
					tieDBItem.id = onedriveJSONItem["id"].str;
				}
			} else {
				tieDBItem.driveId = onedriveJSONItem["parentReference"]["driveId"].str;
				tieDBItem.id = onedriveJSONItem["id"].str;
			}
		}
		
		// set the item type
		tieDBItem.type = ItemType.root;
		
		// get the lastModifiedDateTime
		lastModifiedTimestamp = strip(onedriveJSONItem["fileSystemInfo"]["lastModifiedDateTime"].str);
		// is lastModifiedTimestamp valid?
		if (isValidUTCDateTime(lastModifiedTimestamp)) {
			// string is a valid timestamp
			tieDBItem.mtime = SysTime.fromISOExtString(lastModifiedTimestamp);
		} else {
			// invalid timestamp from JSON file
			addLogEntry("WARNING: Invalid timestamp provided by the Microsoft OneDrive API: " ~ lastModifiedTimestamp);
			// Set mtime to SysTime(0)
			tieDBItem.mtime = SysTime(0);
		}
		
		// Ensure there is no parentId for this DB record
		tieDBItem.parentId = null;
		
		// OneDrive Business supports relocating Shared Folders to other folders.
		// This means, in our DB, we need this DB record to have the correct parentId of the parental folder, if this is relocated shared folder
		// This is stored in the 'relocParentId' DB entry
		// This 'relocatedFolderParentId' variable is only ever set if using OneDrive Business account types and the shared folder is located online in another folder
		if ((!relocatedFolderDriveId.empty) && (!relocatedFolderParentId.empty)) {
			// Ensure that we set the relocParentId to the provided relocatedFolderParentId record
			if (debugLogging) {addLogEntry("Relocated Shared Folder references were provided - adding these to the 'root' DB Tie Record", ["debug"]);}
			tieDBItem.relocDriveId = relocatedFolderDriveId;
			tieDBItem.relocParentId = relocatedFolderParentId;
		}
		
		// Issue #3115 - Validate driveId length
		// What account type is this?
		if (appConfig.accountType == "personal") {
			// Issue #3336 - Convert driveId to lowercase before any test
			tieDBItem.driveId = transformToLowerCase(tieDBItem.driveId);
			
			// Test driveId length and validation if the driveId we are testing is not equal to appConfig.defaultDriveId
			if (tieDBItem.driveId != appConfig.defaultDriveId) {
				tieDBItem.driveId = testProvidedDriveIdForLengthIssue(tieDBItem.driveId);
			}
		}
		
		// Add this DB Tie parent record to the local database
		if (debugLogging) {addLogEntry("Creating|Updating into local database a 'root' DB Tie record for a OneDrive Shared Folder online: " ~ to!string(tieDBItem), ["debug"]);}
		itemDB.upsert(tieDBItem);
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Create a DB Tie Record for a Shared Folder 
	void createDatabaseTieRecordForOnlineSharedFolder(Item parentItem) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Creating|Updating a DB Tie
		if (debugLogging) {
			//addLogEntry("Creating|Updating a DB Tie Record for this Shared Folder: " ~ parentItem.name, ["debug"]);
			addLogEntry("Creating|Updating a DB Tie Record for this Shared Folder from the provided parental data: " ~ parentItem.name, ["debug"]);
			addLogEntry("Parent Item Record: " ~ to!string(parentItem), ["debug"]);
		}
		
		// New DB Tie Item to bind the 'remote' path to our parent path in the database
		Item tieDBItem;
		tieDBItem.name = parentItem.name;
		tieDBItem.id = parentItem.remoteId;
		tieDBItem.type = ItemType.dir;
		tieDBItem.mtime = parentItem.mtime;
		
		// Initially set this
		tieDBItem.driveId = parentItem.remoteDriveId;
		
		// What account type is this as this determines what 'tieDBItem.parentId' should be set to
		// There is a difference in the JSON responses between 'personal' and 'business' account types for Shared Folders
		// Essentially an API inconsistency
		if (appConfig.accountType == "personal") {
			// Set tieDBItem.parentId to null
			tieDBItem.parentId = null;
			tieDBItem.type = ItemType.root;
			
			// Issue #3136, #3139 #3143
			// Fetch the actual online record for this item
			// This returns the actual OneDrive Personal driveId value and is 15 character checked
			string actualOnlineDriveId = testProvidedDriveIdForLengthIssue(fetchRealOnlineDriveIdentifier(tieDBItem.driveId));
			tieDBItem.driveId = actualOnlineDriveId;
		} else {
			// The tieDBItem.parentId needs to be the correct driveId id reference
			// Query the DB 
			Item[] rootDriveItems;
			Item dbRecord;
			rootDriveItems = itemDB.selectByDriveId(parentItem.remoteDriveId);
			
			// Fix Issue #2883
			if (rootDriveItems.length > 0) {
				// Use the first record returned
				dbRecord = rootDriveItems[0];
				tieDBItem.parentId = dbRecord.id;
			} else {
				// Business Account ... but itemDB.selectByDriveId returned no entries ... need to query for this item online to get the correct details given they are not in the database
				if (debugLogging) {addLogEntry("itemDB.selectByDriveId(parentItem.remoteDriveId) returned zero database entries for this remoteDriveId: " ~ to!string(parentItem.remoteDriveId), ["debug"]);}
			
				// Create a new API Instance for this query and initialise it
				OneDriveApi getPathDetailsApiInstance;
				JSONValue latestOnlineDetails;
				getPathDetailsApiInstance = new OneDriveApi(appConfig);
				getPathDetailsApiInstance.initialise();
			
				try {
					// Get the latest online details
					latestOnlineDetails = getPathDetailsApiInstance.getPathDetailsById(parentItem.remoteDriveId, parentItem.remoteId);
					if (debugLogging) {addLogEntry("Parent JSON details from Online Query: " ~ to!string(latestOnlineDetails), ["debug"]);}
					
					// Convert JSON to a database compatible item
					Item tempOnlineRecord = makeItem(latestOnlineDetails);
					
					// Configure tieDBItem.parentId to use tempOnlineRecord.id
					tieDBItem.parentId = tempOnlineRecord.id;
			
					// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
					getPathDetailsApiInstance.releaseCurlEngine();
					getPathDetailsApiInstance = null;
					// Perform Garbage Collection
					GC.collect();
			
				} catch (OneDriveException e) {
					// Display error message
					displayOneDriveErrorMessage(e.msg, thisFunctionName);
					
					// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
					getPathDetailsApiInstance.releaseCurlEngine();
					getPathDetailsApiInstance = null;
					// Perform Garbage Collection
					GC.collect();
					return;
				}
			}
			
			// Free the array memory
			rootDriveItems = [];
		}
		
		// Add tie DB record to the local database
		if (debugLogging) {addLogEntry("Creating|Updating into local database a DB Tie record: " ~ to!string(tieDBItem), ["debug"]);}
		itemDB.upsert(tieDBItem);
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// List all the OneDrive Business Shared Items for the user to see
	void listBusinessSharedObjects() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		JSONValue sharedWithMeItems;
		
		// Create a new API Instance for this thread and initialise it
		OneDriveApi sharedWithMeOneDriveApiInstance;
		sharedWithMeOneDriveApiInstance = new OneDriveApi(appConfig);
		sharedWithMeOneDriveApiInstance.initialise();
		
		try {
			sharedWithMeItems = sharedWithMeOneDriveApiInstance.getSharedWithMe();
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			sharedWithMeOneDriveApiInstance.releaseCurlEngine();
			sharedWithMeOneDriveApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			
		} catch (OneDriveException e) {
			// Display error message
			displayOneDriveErrorMessage(e.msg, thisFunctionName);
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			sharedWithMeOneDriveApiInstance.releaseCurlEngine();
			sharedWithMeOneDriveApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			return;
		}
		
		if (sharedWithMeItems.type() == JSONType.object) {
		
			if (count(sharedWithMeItems["value"].array) > 0) {
				// No shared items
				addLogEntry();
				addLogEntry("Listing available OneDrive Business Shared Items:");
				addLogEntry();
				
				// Iterate through the array
				foreach (searchResult; sharedWithMeItems["value"].array) {
				
					// loop variables for each item
					string sharedByName;
					string sharedByEmail;
					
					// Debug response output
					if (debugLogging) {addLogEntry("shared folder entry: " ~ to!string(searchResult), ["debug"]);}
					
					// Configure 'who' this was shared by
					if ("sharedBy" in searchResult["remoteItem"]["shared"]) {
						// we have shared by details we can use
						if ("displayName" in searchResult["remoteItem"]["shared"]["sharedBy"]["user"]) {
							sharedByName = searchResult["remoteItem"]["shared"]["sharedBy"]["user"]["displayName"].str;
						}
						if ("email" in searchResult["remoteItem"]["shared"]["sharedBy"]["user"]) {
							sharedByEmail = searchResult["remoteItem"]["shared"]["sharedBy"]["user"]["email"].str;
						}
					}
					
					// Output query result
					addLogEntry(debugLogBreakType1);
					if (isItemFile(searchResult)) {
						addLogEntry("Shared File:     " ~ to!string(searchResult["name"].str));
					} else {
						addLogEntry("Shared Folder:   " ~ to!string(searchResult["name"].str));
					}
					
					// Detail 'who' shared this
					if ((sharedByName != "") && (sharedByEmail != "")) {
						addLogEntry("Shared By:       " ~ sharedByName ~ " (" ~ sharedByEmail ~ ")");
					} else {
						if (sharedByName != "") {
							addLogEntry("Shared By:       " ~ sharedByName);
						}
					}
					
					// More detail if --verbose is being used
					if (verboseLogging) {
						addLogEntry("Item Id:         " ~ searchResult["remoteItem"]["id"].str, ["verbose"]);
						addLogEntry("Parent Drive Id: " ~ searchResult["remoteItem"]["parentReference"]["driveId"].str, ["verbose"]);
						if ("id" in searchResult["remoteItem"]["parentReference"]) {
							addLogEntry("Parent Item Id:  " ~ searchResult["remoteItem"]["parentReference"]["id"].str, ["verbose"]);
						}
					}
				}
				
				// Close out the loop
				addLogEntry(debugLogBreakType1);
				addLogEntry();
				
			} else {
				// No shared items
				addLogEntry();
				addLogEntry("No OneDrive Business Shared Folders were returned");
				addLogEntry();
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Query all the OneDrive Business Shared Objects to sync only Shared Files
	void queryBusinessSharedObjects() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		JSONValue sharedWithMeItems;
		Item sharedFilesRootDirectoryDatabaseRecord;
		
		// Create a new API Instance for this thread and initialise it
		OneDriveApi sharedWithMeOneDriveApiInstance;
		sharedWithMeOneDriveApiInstance = new OneDriveApi(appConfig);
		sharedWithMeOneDriveApiInstance.initialise();
		
		try {
			sharedWithMeItems = sharedWithMeOneDriveApiInstance.getSharedWithMe();
			
			// We cant shutdown the API instance here, as we reuse it below
			
		} catch (OneDriveException e) {
			// Display error message
			displayOneDriveErrorMessage(e.msg, thisFunctionName);
			
			// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
			sharedWithMeOneDriveApiInstance.releaseCurlEngine();
			sharedWithMeOneDriveApiInstance = null;
			// Perform Garbage Collection
			GC.collect();
			return;
		}
		
		// Valid JSON response
		if (sharedWithMeItems.type() == JSONType.object) {
		
			// Get the configuredBusinessSharedFilesDirectoryName DB item
			// We need this as we need to 'fake' create all the folders for the shared files
			// Then fake create the file entries for the database with the correct parent folder that is the local folder
			itemDB.selectByPath(baseName(appConfig.configuredBusinessSharedFilesDirectoryName), appConfig.defaultDriveId, sharedFilesRootDirectoryDatabaseRecord);
		
			// For each item returned, if a file, process it
			foreach (searchResult; sharedWithMeItems["value"].array) {
			
				// Shared Business Folders are added to the account using 'Add shortcut to My files'
				// We only care here about any remaining 'files' that are shared with the user
				
				if (isItemFile(searchResult)) {
					// Debug response output
					if (debugLogging) {addLogEntry("getSharedWithMe Response Shared File JSON: " ~ sanitiseJSONItem(searchResult), ["debug"]);}
					
					// Make a DB item from this JSON
					Item sharedFileOriginalData = makeItem(searchResult);
					
					// Variables for each item
					string sharedByName;
					string sharedByEmail;
					string sharedByFolderName;
					string newLocalSharedFilePath;
					string newItemPath;
					Item sharedFilesPath;
					JSONValue fileToDownload;
					JSONValue detailsToUpdate;
					JSONValue latestOnlineDetails;
										
					// Configure 'who' this was shared by
					if ("sharedBy" in searchResult["remoteItem"]["shared"]) {
						// we have shared by details we can use
						if ("displayName" in searchResult["remoteItem"]["shared"]["sharedBy"]["user"]) {
							sharedByName = searchResult["remoteItem"]["shared"]["sharedBy"]["user"]["displayName"].str;
						}
						if ("email" in searchResult["remoteItem"]["shared"]["sharedBy"]["user"]) {
							sharedByEmail = searchResult["remoteItem"]["shared"]["sharedBy"]["user"]["email"].str;
						}
					}
					
					// Configure 'who' shared this, so that we can create the directory for that users shared files with us
					if ((sharedByName != "") && (sharedByEmail != "")) {
						sharedByFolderName = sharedByName ~ " (" ~ sharedByEmail ~ ")";
						
					} else {
						if (sharedByName != "") {
							sharedByFolderName = sharedByName;
						}
					}
					
					// Create the local path to store this users shared files with us
					newLocalSharedFilePath = buildNormalizedPath(buildPath(appConfig.configuredBusinessSharedFilesDirectoryName, sharedByFolderName));
					
					// Does the Shared File Users Local Directory to store the shared file(s) exist?
					if (!exists(newLocalSharedFilePath)) {
						// Folder does not exist locally and needs to be created
						addLogEntry("Creating the OneDrive Business Shared File Users Local Directory: " ~ newLocalSharedFilePath);
					
						// Local folder does not exist, thus needs to be created
						mkdirRecurse(newLocalSharedFilePath);
						
						// As this will not be created online, generate a response so it can be saved to the database
						sharedFilesPath = makeItem(createFakeResponse(baseName(newLocalSharedFilePath)));
						
						// Update sharedFilesPath parent items to that of sharedFilesRootDirectoryDatabaseRecord
						sharedFilesPath.parentId = sharedFilesRootDirectoryDatabaseRecord.id;
						
						// Add DB record to the local database
						if (debugLogging) {addLogEntry("Creating|Updating into local database a DB record for storing OneDrive Business Shared Files: " ~ to!string(sharedFilesPath), ["debug"]);}
						itemDB.upsert(sharedFilesPath);
					} else {
						// Folder exists locally, is the folder in the database? 
						// Query DB for this path
						Item dbRecord;
						if (!itemDB.selectByPath(baseName(newLocalSharedFilePath), appConfig.defaultDriveId, dbRecord)) {
							// As this will not be created online, generate a response so it can be saved to the database
							sharedFilesPath = makeItem(createFakeResponse(baseName(newLocalSharedFilePath)));
							
							// Update sharedFilesPath parent items to that of sharedFilesRootDirectoryDatabaseRecord
							sharedFilesPath.parentId = sharedFilesRootDirectoryDatabaseRecord.id;
							
							// Add DB record to the local database
							if (debugLogging) {addLogEntry("Creating|Updating into local database a DB record for storing OneDrive Business Shared Files: " ~ to!string(sharedFilesPath), ["debug"]);}
							itemDB.upsert(sharedFilesPath);
						}
					}
					
					// The file to download JSON details
					fileToDownload = searchResult;
					
					// Get the latest online details
					latestOnlineDetails = sharedWithMeOneDriveApiInstance.getPathDetailsById(sharedFileOriginalData.remoteDriveId, sharedFileOriginalData.remoteId);
					Item tempOnlineRecord = makeItem(latestOnlineDetails);
					
					// With the local folders created, now update 'fileToDownload' to download the file to our location:
					//	"parentReference": {
					//		"driveId": "<account drive id>",
					//		"driveType": "business",
					//		"id": "<local users shared folder id>",
					//	},
					
					// The getSharedWithMe() JSON response also contains an API bug where the 'hash' of the file is not provided
					// Use the 'latestOnlineDetails' response to obtain the hash
					//	"file": {
					//		"hashes": {
					//			"quickXorHash": "<hash value>"
					//		}
					//	},
					//
					
					// The getSharedWithMe() JSON response also contains an API bug where the 'size' of the file is not the actual size of the file
					// The getSharedWithMe() JSON response also contains an API bug where the 'eTag' of the file is not present
					// The getSharedWithMe() JSON response also contains an API bug where the 'lastModifiedDateTime' of the file is date when the file was shared, not the actual date last modified
					
					detailsToUpdate = [
								"parentReference": JSONValue([
															"driveId": JSONValue(appConfig.defaultDriveId),
															"driveType": JSONValue("business"),
															"id": JSONValue(sharedFilesPath.id)
															]),
								"file": JSONValue([
													"hashes":JSONValue([
																		"quickXorHash": JSONValue(tempOnlineRecord.quickXorHash)
																		])
													]),
								"eTag": JSONValue(tempOnlineRecord.eTag)
								];
					
					foreach (string key, JSONValue value; detailsToUpdate.object) {
						fileToDownload[key] = value;
					}
					
					// Update specific items
					// Update 'size'
					fileToDownload["size"] = to!int(tempOnlineRecord.size);
					fileToDownload["remoteItem"]["size"] = to!int(tempOnlineRecord.size);
					// Update 'lastModifiedDateTime'
					fileToDownload["lastModifiedDateTime"] = latestOnlineDetails["fileSystemInfo"]["lastModifiedDateTime"].str;
					fileToDownload["fileSystemInfo"]["lastModifiedDateTime"] = latestOnlineDetails["fileSystemInfo"]["lastModifiedDateTime"].str;
					fileToDownload["remoteItem"]["lastModifiedDateTime"] = latestOnlineDetails["fileSystemInfo"]["lastModifiedDateTime"].str;
					fileToDownload["remoteItem"]["fileSystemInfo"]["lastModifiedDateTime"] = latestOnlineDetails["fileSystemInfo"]["lastModifiedDateTime"].str;
					
					// Final JSON that will be used to download the file
					if (debugLogging) {addLogEntry("Final fileToDownload: " ~ to!string(fileToDownload), ["debug"]);}
					
					// Make the new DB item from the consolidated JSON item
					Item downloadSharedFileDbItem = makeItem(fileToDownload);
					
					// Calculate the full local path for this shared file
					newItemPath = computeItemPath(downloadSharedFileDbItem.driveId, downloadSharedFileDbItem.parentId) ~ "/" ~ downloadSharedFileDbItem.name;
					
					// Does this potential file exists on disk?
					if (!exists(newItemPath)) {
						// The shared file does not exists locally
						// Is this something we actually want? Check the JSON against Client Side Filtering Rules
						bool unwanted = checkJSONAgainstClientSideFiltering(fileToDownload);
						if (!unwanted) {
							// File has not been excluded via Client Side Filtering
							// Submit this shared file to be processed further for downloading
							applyPotentiallyNewLocalItem(downloadSharedFileDbItem, fileToDownload, newItemPath);
						}
					} else {
						// A file, in the desired local location already exists with the same name
						// Is this local file in sync?
						string itemSource = "remote";
						if (!isItemSynced(downloadSharedFileDbItem, newItemPath, itemSource)) {
							// Not in sync ....
							Item existingDatabaseItem;
							bool existingDBEntry = itemDB.selectById(downloadSharedFileDbItem.driveId, downloadSharedFileDbItem.id, existingDatabaseItem);
							
							// Is there a DB entry?
							if (existingDBEntry) {
								// Existing DB entry
								// Need to be consistent here with how 'newItemPath' was calculated
								string existingItemPath = computeItemPath(existingDatabaseItem.driveId, existingDatabaseItem.parentId) ~ "/" ~ existingDatabaseItem.name;
								// Attempt to apply this changed item
								applyPotentiallyChangedItem(existingDatabaseItem, existingItemPath, downloadSharedFileDbItem, newItemPath, fileToDownload);
							} else {
								// File exists locally, it is not in sync, there is no record in the DB of this file
								// In case the renamed path is needed
								string renamedPath;
								// If local data protection is configured (bypassDataPreservation = false), safeBackup the local file, passing in if we are performing a --dry-run or not
								safeBackup(newItemPath, dryRun, bypassDataPreservation, renamedPath);
								// Submit this shared file to be processed further for downloading
								applyPotentiallyNewLocalItem(downloadSharedFileDbItem, fileToDownload, newItemPath);
							}
						} else {
							// Item is in sync, ensure the DB record is the same
							itemDB.upsert(downloadSharedFileDbItem);
						}
					}
				}
			}
		}
		
		// OneDrive API Instance Cleanup - Shutdown API, free curl object and memory
		sharedWithMeOneDriveApiInstance.releaseCurlEngine();
		sharedWithMeOneDriveApiInstance = null;
		// Perform Garbage Collection
		GC.collect();
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Renaming or moving a directory online manually using --source-directory 'path/as/source/' --destination-directory 'path/as/destination'
	void moveOrRenameDirectoryOnline(string sourcePath, string destinationPath) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// Function Variables
		bool sourcePathExists = false;
		bool destinationPathExists = false;
		bool invalidDestination = false;
		JSONValue sourcePathData;
		JSONValue destinationPathData;
		JSONValue parentPathData;
		Item sourceItem;
		Item parentItem;
		
		// Log that we are doing a move
		addLogEntry("Moving " ~ sourcePath ~ " to " ~ destinationPath);
		
		// Create a new API Instance for this thread and initialise it
		OneDriveApi onlineMoveApiInstance;
		onlineMoveApiInstance = new OneDriveApi(appConfig);
		onlineMoveApiInstance.initialise();
		
		// In order to move, the 'source' needs to exist online, so this is the first check
		try {
			sourcePathData = onlineMoveApiInstance.getPathDetails(sourcePath);
			sourceItem = makeItem(sourcePathData);
			sourcePathExists = true;
		} catch (OneDriveException exception) {
		
			if (exception.httpStatusCode == 404) {
				// The item to search was not found. If it does not exist, how can we move it?
				addLogEntry("The source path to move does not exist online - unable to move|rename a path that does not already exist online");
				forceExit();
			} else {
				// An error, regardless of what it is ... not good
				// Display what the error is
				// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
				forceExit();
			}
		}
		
		// The second check needs to be that the destination does not already exist
		try {
			destinationPathData = onlineMoveApiInstance.getPathDetails(destinationPath);
			destinationPathExists = true;
			addLogEntry("The destination path to move to exists online - unable to move|rename to a path that already exists online");
			forceExit();
		} catch (OneDriveException exception) {
		
			if (exception.httpStatusCode == 404) {
				// The item to search was not found. This is good as the destination path is empty
			} else {
				// An error, regardless of what it is ... not good
				// Display what the error is
				// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
				displayOneDriveErrorMessage(exception.msg, thisFunctionName);
				forceExit();
			}
		}
		
		// Can we move?
		if ((sourcePathExists) && (!destinationPathExists)) {
			// Make an item we can use
			Item onlineItem = makeItem(sourcePathData);
		
			// The directory to move MUST be a directory
			if (onlineItem.type == ItemType.dir) {
			
				// Validate that the 'destination' is valid
				
				// This not a Client Side Filtering check, nor a Microsoft Check, but is a sanity check that the path provided is UTF encoded correctly
				// Check the std.encoding of the path against: Unicode 5.0, ASCII, ISO-8859-1, ISO-8859-2, WINDOWS-1250, WINDOWS-1251, WINDOWS-1252
				if (!invalidDestination) {
					if(!isValid(destinationPath)) {
						// Path is not valid according to https://dlang.org/phobos/std_encoding.html
						addLogEntry("Skipping move - invalid character encoding sequence: " ~ destinationPath, ["info", "notify"]);
						invalidDestination = true;
					}
				}
				
				// We do not check this path against the Client Side Filtering Rules as this is 100% an online move only
				
				// Check this path against the Microsoft Naming Conventions & Restrictions
				// - Check path against Microsoft OneDrive restriction and limitations about Windows naming for files and folders
				// - Check path for bad whitespace items
				// - Check path for HTML ASCII Codes
				// - Check path for ASCII Control Codes
				if (!invalidDestination) {
					invalidDestination = checkPathAgainstMicrosoftNamingRestrictions(destinationPath, "move");
				}
				
				// Is the destination location invalid?
				if (!invalidDestination) {
					// We can perform the online move
					// We need to query for the parent information of the destination path
					string parentPath = dirName(destinationPath);
					
					// Configure the parentItem by if this is the account 'root' use the root details, or query online for the parent details
					if (parentPath == ".") {
						// Parent path is '.' which is the account root - use client defaults
						parentItem.driveId = appConfig.defaultDriveId; 	// Should give something like 12345abcde1234a1
						parentItem.id = appConfig.defaultRootId;  		// Should give something like 12345ABCDE1234A1!101
					} else {
						// Need to query to obtain the details
						try {
							if (debugLogging) {addLogEntry("Attempting to query OneDrive Online for this parent path: " ~ parentPath, ["debug"]);}
							parentPathData = onlineMoveApiInstance.getPathDetails(parentPath);
							if (debugLogging) {addLogEntry("Online Parent Path Query Response: " ~ to!string(parentPathData), ["debug"]);}
							parentItem = makeItem(parentPathData);
						} catch (OneDriveException exception) {
							if (exception.httpStatusCode == 404) {
								// The item to search was not found. If it does not exist, how can we move it?
								addLogEntry("The parent path to move to does not exist online - unable to move|rename a path to a parent that does exist online");
								forceExit();
							} else {
								// Display what the error is
								// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
								displayOneDriveErrorMessage(exception.msg, thisFunctionName);
								forceExit();
							}
						}
					}
					
					// Configure the modification JSON item
					SysTime mtime;
					// Use the current system time
					mtime = Clock.currTime().toUTC();
					
					JSONValue data = [
						"name": JSONValue(baseName(destinationPath)),
						"parentReference": JSONValue([
							"id": parentItem.id
						]),
						"fileSystemInfo": JSONValue([
							"lastModifiedDateTime": mtime.toISOExtString()
						])
					];
					
					// Try the online move
					try {
						onlineMoveApiInstance.updateById(sourceItem.driveId, sourceItem.id, data, sourceItem.eTag);
						// Log that it was successful
						addLogEntry("Successfully moved " ~ sourcePath ~ " to " ~ destinationPath);
					} catch (OneDriveException exception) {
						// Display what the error is
						// - 408,429,503,504 errors are handled as a retry within uploadFileOneDriveApiInstance
						displayOneDriveErrorMessage(exception.msg, thisFunctionName);
						forceExit();	
					}
				}
			} else {
				// The source item is not a directory
				addLogEntry("ERROR: The source path to move is not a directory");
				forceExit();
			}
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	}
	
	// Return an array of the notification parameters when this is called. This implements FR #2760
	string[] fileTransferNotifications() {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		// Based on the configuration option, send the file transfer actions to the GUI notifications if configured
		// GUI notifications are already sent for files that meet this criteria:
		// - Skipping a particular item due to an invalid name
		// - Skipping a particular item due to an invalid symbolic link
		// - Skipping a particular item due to an invalid UTF sequence
		// - Skipping a particular item due to an invalid character encoding sequence
		// - Files that fail to upload
		// - Files that fail to download
		//
		// This is about notifying on:
		// - Successful file download
		// - Successful file upload
		// - Successful deletion locally
		// - Successful deletion online
		
		string[] loggingOptions;
		
		if (appConfig.getValueBool("notify_file_actions")) {
			// Add the 'notify' to enable GUI notifications
			loggingOptions = ["info", "notify"];
		} else {
			// Logging to console and/or logfile only
			loggingOptions = ["info"];
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
	
		return loggingOptions;
	}
	
	// OneDrive Personal driveId or parentReference driveId must be 16 characters in length
	string testProvidedDriveIdForLengthIssue(string objectParentDriveId) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Due to this function, we need to keep the return <string value>; code, so that this function operates as efficiently as possible.
		// Whilst this means some extra code / duplication in this function, it cannot be helped
	
		// OneDrive Personal Account driveId and remoteDriveId length check
		// Issue #3072 (https://github.com/abraunegg/onedrive/issues/3072) illustrated that the OneDrive API is inconsistent in response when the Drive ID starts with a zero ('0')
		// - driveId
		// - remoteDriveId
		// 
		// Example:
		//   024470056F5C3E43 (driveId)
		//   24470056f5c3e43  (remoteDriveId)
		//
		// If this is a OneDrive Personal Account, ensure this value is 16 characters, padded by leading zero's if eventually required
		
		string oldEntry;
		string newEntry;
		
		// Check the provided objectParentDriveId
		if (!objectParentDriveId.empty) {
			// Ensure objectParentDriveId is 16 characters long by padding with leading zeros if required
			if (debugLogging) {
				string validationMessage = format("Validating that the provided OneDrive Personal 'driveId' value '%s' is 16 characters", objectParentDriveId);
				addLogEntry(validationMessage, ["debug"]);
			}
			
			// Is this less than 16 characters
			if (objectParentDriveId.length < 16) {
				// Debug logging
				if (debugLogging) {addLogEntry("ONEDRIVE PERSONAL API BUG (Issue #3072): The provided 'driveId' is not 16 characters in length - fetching the correct value from Microsoft Graph API via getDriveIdRoot call", ["debug"]);}
				
				// Generate the change
				oldEntry = objectParentDriveId;
				string onlineDriveValue;
				
				// Fetch the actual online record for this item
				// This returns the actual OneDrive Personal driveId value based on the input value.
				// The function 'fetchRealOnlineDriveIdentifier' does not check for length issue, this is done below
				onlineDriveValue = fetchRealOnlineDriveIdentifier(oldEntry);
				
				// Check the onlineDriveValue value for 15 character issue
				if (!onlineDriveValue.empty) {
					// Ensure remoteDriveId is 16 characters long by padding with leading zeros if required
					if (onlineDriveValue.length < 16) {
						// online value is not 16 characters in length
						// Debug logging
						if (debugLogging) {addLogEntry("ONEDRIVE PERSONAL API BUG (Issue #3072): The provided online ['parentReference']['driveId'] value is not 16 Characters in length - padding with leading zero's", ["debug"]);}
						// Generate the change
						newEntry = to!string(onlineDriveValue.padLeft('0', 16)); // Explicitly use padLeft for leading zero padding, leave case as-is
					} else {
						// Online value is 16 characters in length, use as-is
						newEntry = onlineDriveValue;
					}
				}
				
				// Debug Logging of result
				if (debugLogging) {
						addLogEntry(" - old 'driveId' value = " ~ oldEntry, ["debug"]);
						addLogEntry(" - new 'driveId' value = " ~ newEntry, ["debug"]);
				}
				
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
				
				// Issue #3336 - Convert driveId to lowercase
				// Return the new calculated value as lowercase
				return transformToLowerCase(newEntry);
			} else {
				// Display function processing time if configured to do so
				if (appConfig.getValueBool("display_processing_time") && debugLogging) {
					// Combine module name & running Function
					displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
				}
			
				// Issue #3336 - Convert driveId to lowercase
				// Return input value as-is as lowercase
				return transformToLowerCase(objectParentDriveId);
			}
		} else {
			// Display function processing time if configured to do so
			if (appConfig.getValueBool("display_processing_time") && debugLogging) {
				// Combine module name & running Function
				displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
			}
		
			// Issue #3336 - Convert driveId to lowercase
			// Return input value as-is as lowercase
			return transformToLowerCase(objectParentDriveId);
		}
	}
	
	// Transform OneDrive Personal driveId or parentReference driveId to lowercase
	string transformToLowerCase(string objectParentDriveId) {
		// Since 14 June 2025 (possibly earlier), the Microsoft Graph API has started returning inconsistent casing for driveId values across multiple OneDrive Personal API endpoints.
		// https://github.com/OneDrive/onedrive-api-docs/issues/1902
	
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
	
		string transformedDriveIdValue;
		transformedDriveIdValue = toLower(objectParentDriveId);
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// Return transformed value
		return transformedDriveIdValue;
	}
	
	// Calculate the transfer metrics for the file to aid in performance discussions when they are raised
	void displayTransferMetrics(string fileTransferred, long transferredBytes, SysTime transferStartTime, SysTime transferEndTime) {
		// We only calculate this if 'display_transfer_metrics' is enabled or we are doing debug logging
		if (appConfig.getValueBool("display_transfer_metrics") || debugLogging) {
		
			// Function Start Time
			SysTime functionStartTime;
			string logKey;
			string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
			// Only set this if we are generating performance processing times
			if (appConfig.getValueBool("display_processing_time") && debugLogging) {
				functionStartTime = Clock.currTime();
				logKey = generateAlphanumericString();
				displayFunctionProcessingStart(thisFunctionName, logKey);
			}
		
	
			// Calculations must be done on files > 0 transferredBytes
			if (transferredBytes > 0) {
				// Calculate transfer metrics
				auto transferDuration = transferEndTime - transferStartTime;
				double transferDurationAsSeconds = (transferDuration.total!"msecs"/1e3); // msec --> seconds
				double transferSpeedAsMbps = ((transferredBytes / transferDurationAsSeconds) / 1024 / 1024); // bytes --> Mbps
				
				// Output the transfer metrics
				string transferMetrics = format("File: %s | Size: %d Bytes | Duration: %.2f Seconds | Speed: %.2f Mbps (approx)", fileTransferred, transferredBytes, transferDurationAsSeconds, transferSpeedAsMbps);
				addLogEntry("Transfer Metrics - " ~ transferMetrics);
				
			} else {
				// Zero bytes - not applicable
				addLogEntry("Transfer Metrics - N/A (Zero Byte File)");
			}
			
			// Display function processing time if configured to do so
			if (appConfig.getValueBool("display_processing_time") && debugLogging) {
				// Combine module name & running Function
				displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
			}
		}
	}
	
	// Recursively validate JSONValue for UTF-8 compliance
	bool validateUTF8JSON(in JSONValue json) {
		switch (json.type) {
			case JSONType.string:
				return isValidUTF8(json.str);
			case JSONType.array:
				foreach (ref item; json.array) {
					if (!validateUTF8JSON(item)) return false;
				}
				break;
			case JSONType.object:
				foreach (key, ref value; json.object) {
					if (!isValidUTF8(key) || !validateUTF8JSON(value)) return false;
				}
				break;
			default:
				break; // Other types (null, bool, int, float) don't need UTF-8 validation
		}
		return true;
	}
	
	// Sanitise the provided onedriveJSONItem into a string that can actually be printed without error or issue
	string sanitiseJSONItem(JSONValue onedriveJSONItem) {
		// Function Start Time
		SysTime functionStartTime;
		string logKey;
		string thisFunctionName = format("%s.%s", strip(__MODULE__) , strip(getFunctionName!({})));
		// Only set this if we are generating performance processing times
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			functionStartTime = Clock.currTime();
			logKey = generateAlphanumericString();
			displayFunctionProcessingStart(thisFunctionName, logKey);
		}
		
		// Eventual output variable
		string sanitisedJSONString;
		
		// Validate UTF-8 before serialisation
		if (!validateUTF8JSON(onedriveJSONItem)) {
			return "JSON Validation Failed: JSON data from OneDrive API contains invalid UTF-8 characters";
		}
		
		// Try and serialise the JSON into a string
		try {
			auto app = appender!string();
			toJSON(app, onedriveJSONItem);
			sanitisedJSONString = app.data;
		} catch (Exception e) {
			sanitisedJSONString = "JSON Serialisation Failed: " ~ e.msg;
		}
		
		// Display function processing time if configured to do so
		if (appConfig.getValueBool("display_processing_time") && debugLogging) {
			// Combine module name & running Function
			displayFunctionProcessingTime(thisFunctionName, functionStartTime, Clock.currTime(), logKey);
		}
		
		// Return sanitised JSON string for logging output
		return sanitisedJSONString;
	}
}
