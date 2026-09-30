#!/usr/bin/env python3
"""Structural integration checks, not a substitute for a Windows build/runtime."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
source = (root / 'runner/native_channels.cpp').read_text()
web = (root / 'runner/strava_web_plugin.cpp').read_text()
oauth = (root / 'runner/strava_oauth.cpp').read_text()
zone = (root / 'runner/windows_timezone.cpp').read_text()
all_source = source + web + oauth
header = (root / 'runner/native_channel_validation.h').read_text()
window = (root / 'runner/flutter_window.cpp').read_text()
cmake = (root / 'runner/CMakeLists.txt').read_text()
channels = {'keychain', 'third_party_vault', 'preferences', 'sync_files', 'files',
            'healthkit', 'strava_web', 'strava_oauth'}
assert set(re.findall(r'  add\("([a-z_]+)"', source)) | set(re.findall(r'"health_workout_export/(strava_web|strava_oauth)"', source)) == channels
for method in ('stravaStatus', 'stravaLease', 'writeStravaAuthorization', 'clearStravaAuthorization',
               'xingzheStatus', 'xingzheLease', 'writeXingzheAuthorization', 'clearXingzheAuthorization',
               'onelapStatus', 'onelapLease', 'writeOnelapAuthorization', 'clearOnelapAuthorization',
               'readState', 'writeState', 'deleteState', 'readSyncedFit', 'writeSyncedFit',
               'deleteSyncedFit', 'readRecovery', 'writeRecovery', 'deleteRecovery',
               'readBatchSession', 'writeBatchSession', 'deleteBatchSession',
               'pickFits', 'openActivity', 'isAvailable', 'fetchWorkoutBundles',
               'deleteActivity', 'listActivityPage', 'readActivitySpeedData'):
    assert f'"{method}"' in all_source, method
for api in ('CredReadW', 'CredWriteW', 'CredDeleteW', 'CRED_PERSIST_LOCAL_MACHINE',
            'SHGetKnownFolderPath', 'FOLDERID_LocalAppData', 'SetSecurityInfo',
            'PROTECTED_DACL_SECURITY_INFORMATION', 'FILE_FLAG_OPEN_REPARSE_POINT',
            'FlushFileBuffers', 'MOVEFILE_REPLACE_EXISTING', 'MOVEFILE_WRITE_THROUGH',
            'nNumberOfLinks != 1', 'CoCreateInstance', 'FOS_FORCEFILESYSTEM'):
    assert api in source, api
assert 'std::make_unique<NativeChannels>' in window
assert window.index('native_channels_.reset()') < window.index('flutter_controller_ = nullptr')
assert '"native_channels.cpp"' in cmake
for library in ('advapi32.lib', 'shell32.lib', 'ole32.lib', 'uuid.lib'):
    assert library in cmake, library
assert 'next["onelap.refresh"] = Stored(state, "onelap.refresh")' not in source
assert 'RequiredText(call, "refreshToken", &next["onelap.refresh"])' in source
assert 'Omission/null clears it' in source
assert 'payload[Value("refreshToken")] = Value(Stored(state, "onelap.refresh"))' in source
assert 'native_channels::IsActivityId(id)' in web
assert 'strava_web::kOrigin' in web
assert 'native_channels::IsFingerprint(*fingerprint)' in source
assert 'native_channels::IsPreferenceKey(*key)' in source
assert 'not implemented on Windows' not in all_source
assert 'WINHTTP_DISABLE_REDIRECTS' in web and 'WINHTTP_DISABLE_COOKIES' in web
assert 'WINHTTP_FLAG_SECURE' in web and 'SECURITY_FLAG_IGNORE' not in web
assert 'CreateCoreWebView2EnvironmentWithOptions' in web and 'get_CookieManager' in web
assert 'ucal_getTimeZoneIDForWindowsID' in zone and 'LOAD_LIBRARY_SEARCH_SYSTEM32' in zone
assert 'oauth_plugin_->Handle(call, std::move(result))' in source
assert 'web_plugin_->Handle(call, std::move(result))' in source
assert 'sync_file_corrupt' in source and 'storage.Quarantine' in source
assert 'strava.accessToken' not in header[header.index('inline bool IsPreferenceKey'):header.index('inline bool IsNonEmptyText')]
print('Windows native channel registration, security API, vault, async-web/OAuth and timezone contract checks passed')
