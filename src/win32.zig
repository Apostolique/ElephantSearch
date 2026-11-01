//! Raw Win32 bindings for the volume and USN journal control codes.
//! std.os.windows does not expose these, so they are declared here.

const std = @import("std");

pub const HANDLE = *anyopaque;
pub const BOOL = i32;
pub const DWORD = u32;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

pub extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;

pub extern "kernel32" fn DeviceIoControl(
    hDevice: HANDLE,
    dwIoControlCode: DWORD,
    lpInBuffer: ?*const anyopaque,
    nInBufferSize: DWORD,
    lpOutBuffer: ?*anyopaque,
    nOutBufferSize: DWORD,
    lpBytesReturned: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetLogicalDrives() callconv(.winapi) DWORD;

pub extern "kernel32" fn GetVolumeInformationW(
    lpRootPathName: ?[*:0]const u16,
    lpVolumeNameBuffer: ?[*]u16,
    nVolumeNameSize: DWORD,
    lpVolumeSerialNumber: ?*DWORD,
    lpMaximumComponentLength: ?*DWORD,
    lpFileSystemFlags: ?*DWORD,
    lpFileSystemNameBuffer: ?[*]u16,
    nFileSystemNameSize: DWORD,
) callconv(.winapi) BOOL;

pub const GENERIC_READ: DWORD = 0x8000_0000;
pub const FILE_SHARE_READ: DWORD = 0x0000_0001;
pub const FILE_SHARE_WRITE: DWORD = 0x0000_0002;
pub const FILE_SHARE_DELETE: DWORD = 0x0000_0004;
pub const OPEN_EXISTING: DWORD = 3;
pub const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x0200_0000;
pub const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x0000_0010;

pub const DRIVE_FIXED: DWORD = 3;

// CTL_CODE(FILE_DEVICE_FILE_SYSTEM=9, function, method, FILE_ANY_ACCESS)
pub const FSCTL_ENUM_USN_DATA: DWORD = 0x0009_00B3;
pub const FSCTL_READ_USN_JOURNAL: DWORD = 0x0009_00BB;
pub const FSCTL_CREATE_USN_JOURNAL: DWORD = 0x0009_00E7;
pub const FSCTL_QUERY_USN_JOURNAL: DWORD = 0x0009_00F4;

pub const ERROR_ACCESS_DENIED: DWORD = 5;
pub const ERROR_HANDLE_EOF: DWORD = 38;
pub const ERROR_NOT_SUPPORTED: DWORD = 50;
pub const ERROR_MORE_DATA: DWORD = 234;
pub const ERROR_JOURNAL_DELETE_IN_PROGRESS: DWORD = 1178;
pub const ERROR_JOURNAL_NOT_ACTIVE: DWORD = 1179;
pub const ERROR_JOURNAL_ENTRY_DELETED: DWORD = 1181;
pub const ERROR_INVALID_PARAMETER: DWORD = 87;

pub const MftEnumData = extern struct {
    StartFileReferenceNumber: u64,
    LowUsn: i64,
    HighUsn: i64,
};

pub const UsnJournalData = extern struct {
    UsnJournalID: u64,
    FirstUsn: i64,
    NextUsn: i64,
    LowestValidUsn: i64,
    MaxUsn: i64,
    MaximumSize: u64,
    AllocationDelta: u64,
};

pub const ReadUsnJournalData = extern struct {
    StartUsn: i64,
    ReasonMask: u32,
    ReturnOnlyOnClose: u32,
    Timeout: u64,
    BytesToWaitFor: u64,
    UsnJournalID: u64,
};

pub const CreateUsnJournalData = extern struct {
    MaximumSize: u64,
    AllocationDelta: u64,
};

/// The variable-length name starts at `FileNameOffset`, which is 60 here even
/// though the struct pads out to 64. Never use @sizeOf to find it.
pub const UsnRecordV2 = extern struct {
    RecordLength: u32,
    MajorVersion: u16,
    MinorVersion: u16,
    FileReferenceNumber: u64,
    ParentFileReferenceNumber: u64,
    Usn: i64,
    TimeStamp: i64,
    Reason: u32,
    SourceInfo: u32,
    SecurityId: u32,
    FileAttributes: u32,
    FileNameLength: u16,
    FileNameOffset: u16,

    pub fn fileName(self: *align(1) const UsnRecordV2) []align(1) const u16 {
        const base: [*]const u8 = @ptrCast(self);
        const ptr: [*]align(1) const u16 = @ptrCast(base + self.FileNameOffset);
        return ptr[0 .. self.FileNameLength / 2];
    }

    pub fn isDir(self: *align(1) const UsnRecordV2) bool {
        return self.FileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0;
    }
};

comptime {
    std.debug.assert(@offsetOf(UsnRecordV2, "FileReferenceNumber") == 8);
    std.debug.assert(@offsetOf(UsnRecordV2, "ParentFileReferenceNumber") == 16);
    std.debug.assert(@offsetOf(UsnRecordV2, "Reason") == 40);
    std.debug.assert(@offsetOf(UsnRecordV2, "FileAttributes") == 52);
    std.debug.assert(@offsetOf(UsnRecordV2, "FileNameLength") == 56);
    std.debug.assert(@offsetOf(UsnRecordV2, "FileNameOffset") == 58);
}

pub const USN_REASON_FILE_CREATE: u32 = 0x0000_0100;
pub const USN_REASON_FILE_DELETE: u32 = 0x0000_0200;
pub const USN_REASON_RENAME_OLD_NAME: u32 = 0x0000_1000;
pub const USN_REASON_RENAME_NEW_NAME: u32 = 0x0000_2000;
pub const USN_REASON_CLOSE: u32 = 0x8000_0000;

pub extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) BOOL;

/// Monotonic timer. std.time.Timer is gone in 0.16 and the replacement wants an
/// Io handle passed down every call site, which these hot paths do not have.
pub const Timer = struct {
    start_ticks: i64,

    pub fn start() Timer {
        var t: i64 = 0;
        _ = QueryPerformanceCounter(&t);
        return .{ .start_ticks = t };
    }

    pub fn readNanos(self: Timer) u64 {
        var now: i64 = 0;
        _ = QueryPerformanceCounter(&now);
        var freq: i64 = 1;
        _ = QueryPerformanceFrequency(&freq);
        if (freq <= 0) return 0;
        const elapsed: u128 = @intCast(@max(now - self.start_ticks, 0));
        return @intCast(elapsed * 1_000_000_000 / @as(u128, @intCast(freq)));
    }

    pub fn readMillis(self: Timer) u64 {
        return self.readNanos() / 1_000_000;
    }
};

pub const STD_INPUT_HANDLE: DWORD = 0xFFFF_FFF6;
pub const STD_OUTPUT_HANDLE: DWORD = 0xFFFF_FFF5;

pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;
pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
pub extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) callconv(.winapi) BOOL;

pub extern "kernel32" fn ReadConsoleInputW(
    hConsoleInput: HANDLE,
    lpBuffer: [*]InputRecord,
    nLength: DWORD,
    lpNumberOfEventsRead: *DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetNumberOfConsoleInputEvents(
    hConsoleInput: HANDLE,
    lpNumberOfEvents: *DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetConsoleScreenBufferInfo(
    hConsoleOutput: HANDLE,
    lpConsoleScreenBufferInfo: *ConsoleScreenBufferInfo,
) callconv(.winapi) BOOL;

// Input modes. Line and echo have to go for key-at-a-time reading, processed
// has to go for ctrl+c to arrive as a key, and quick edit only actually clears
// when extended flags is set alongside it.
pub const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
pub const ENABLE_LINE_INPUT: DWORD = 0x0002;
pub const ENABLE_ECHO_INPUT: DWORD = 0x0004;
pub const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
pub const ENABLE_QUICK_EDIT_MODE: DWORD = 0x0040;
pub const ENABLE_EXTENDED_FLAGS: DWORD = 0x0080;

pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;

pub const CP_UTF8: u32 = 65001;

pub const KEY_EVENT: u16 = 0x0001;
pub const WINDOW_BUFFER_SIZE_EVENT: u16 = 0x0004;

pub const VK_BACK: u16 = 0x08;
pub const VK_RETURN: u16 = 0x0D;
pub const VK_ESCAPE: u16 = 0x1B;
pub const VK_PRIOR: u16 = 0x21;
pub const VK_NEXT: u16 = 0x22;
pub const VK_END: u16 = 0x23;
pub const VK_HOME: u16 = 0x24;
pub const VK_LEFT: u16 = 0x25;
pub const VK_UP: u16 = 0x26;
pub const VK_RIGHT: u16 = 0x27;
pub const VK_DOWN: u16 = 0x28;
pub const VK_DELETE: u16 = 0x2E;

pub const RIGHT_ALT_PRESSED: DWORD = 0x0001;
pub const LEFT_ALT_PRESSED: DWORD = 0x0002;
pub const RIGHT_CTRL_PRESSED: DWORD = 0x0004;
pub const LEFT_CTRL_PRESSED: DWORD = 0x0008;
pub const SHIFT_PRESSED: DWORD = 0x0010;

pub const Coord = extern struct { x: i16, y: i16 };

pub const SmallRect = extern struct {
    left: i16,
    top: i16,
    right: i16,
    bottom: i16,
};

pub const ConsoleScreenBufferInfo = extern struct {
    size: Coord,
    cursor: Coord,
    attributes: u16,
    /// The part of the buffer actually on screen. The buffer itself is often
    /// thousands of lines tall, so this is the one to size a frame against.
    window: SmallRect,
    max_window: Coord,
};

pub const KeyEventRecord = extern struct {
    key_down: BOOL,
    repeat_count: u16,
    virtual_key_code: u16,
    virtual_scan_code: u16,
    /// The UTF-16 code unit, which is 0 for keys that produce no character.
    char: u16,
    control_key_state: DWORD,
};

/// The union is four-byte aligned, so two bytes of padding sit after the tag.
pub const InputRecord = extern struct {
    event_type: u16,
    _reserved: u16 = 0,
    event: extern union {
        key: KeyEventRecord,
        size: Coord,
        raw: [16]u8,
    },
};

comptime {
    std.debug.assert(@sizeOf(InputRecord) == 20);
    std.debug.assert(@offsetOf(InputRecord, "event") == 4);
    std.debug.assert(@offsetOf(KeyEventRecord, "char") == 10);
    std.debug.assert(@sizeOf(ConsoleScreenBufferInfo) == 22);
}

/// Two halves of a 64-bit tick count, and only four-byte aligned, so it cannot
/// just be declared as an i64 inside a struct the API fills in.
pub const FileTimeParts = extern struct {
    low: u32,
    high: u32,

    pub fn ticks(self: FileTimeParts) i64 {
        return @bitCast((@as(u64, self.high) << 32) | self.low);
    }
};

pub const FileAttributeData = extern struct {
    attributes: DWORD,
    created: FileTimeParts,
    accessed: FileTimeParts,
    written: FileTimeParts,
    size_high: u32,
    size_low: u32,

    pub fn size(self: FileAttributeData) u64 {
        return (@as(u64, self.size_high) << 32) | self.size_low;
    }
};

comptime {
    std.debug.assert(@sizeOf(FileAttributeData) == 36);
}

pub const GetFileExInfoStandard: i32 = 0;

pub extern "kernel32" fn GetFileAttributesExW(
    lpFileName: [*:0]const u16,
    fInfoLevelId: i32,
    lpFileInformation: *FileAttributeData,
) callconv(.winapi) BOOL;

/// Shifts a file time into the machine's zone. Both sides are a bare 64-bit
/// count of 100 ns ticks, which is what FILETIME's two halves add up to.
pub extern "kernel32" fn FileTimeToLocalFileTime(
    lpFileTime: *const i64,
    lpLocalFileTime: *i64,
) callconv(.winapi) BOOL;

pub const GENERIC_WRITE: DWORD = 0x4000_0000;
pub const CREATE_ALWAYS: DWORD = 2;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x0000_0080;
pub const MOVEFILE_REPLACE_EXISTING: DWORD = 0x0000_0001;
pub const ERROR_ALREADY_EXISTS: DWORD = 183;

pub extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreateDirectoryW(
    lpPathName: [*:0]const u16,
    lpSecurityAttributes: ?*anyopaque,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetEnvironmentVariableW(
    lpName: [*:0]const u16,
    lpBuffer: ?[*]u16,
    nSize: DWORD,
) callconv(.winapi) DWORD;

pub extern "kernel32" fn MoveFileExW(
    lpExistingFileName: [*:0]const u16,
    lpNewFileName: ?[*:0]const u16,
    dwFlags: DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) BOOL;

/// A null module is this program's own binary, full path included.
pub extern "kernel32" fn GetModuleFileNameW(
    hModule: ?HANDLE,
    lpFilename: [*]u16,
    nSize: DWORD,
) callconv(.winapi) DWORD;

pub const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFF_FFFF;

pub extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) DWORD;

pub const FILE_BEGIN: DWORD = 0;

pub extern "kernel32" fn SetFilePointerEx(
    hFile: HANDLE,
    liDistanceToMove: i64,
    lpNewFilePointer: ?*i64,
    dwMoveMethod: DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 258;

pub extern "kernel32" fn WaitForSingleObject(
    hHandle: HANDLE,
    dwMilliseconds: DWORD,
) callconv(.winapi) DWORD;

pub const CF_UNICODETEXT: u32 = 13;
pub const GMEM_MOVEABLE: u32 = 0x0002;

pub extern "user32" fn OpenClipboard(hWndNewOwner: ?HANDLE) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn SetClipboardData(uFormat: u32, hMem: ?HANDLE) callconv(.winapi) ?HANDLE;

pub extern "kernel32" fn GlobalAlloc(uFlags: u32, dwBytes: usize) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GlobalFree(hMem: ?HANDLE) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GlobalLock(hMem: HANDLE) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(hMem: HANDLE) callconv(.winapi) BOOL;

pub const SW_SHOWNORMAL: i32 = 1;

pub const HRESULT = i32;

/// A shell item identifier list. Only ever held as a pointer.
pub const ItemIdList = opaque {};

pub extern "shell32" fn ILCreateFromPathW(pszPath: [*:0]const u16) callconv(.winapi) ?*ItemIdList;
pub extern "shell32" fn ILFree(pidl: ?*ItemIdList) callconv(.winapi) void;

pub extern "shell32" fn SHOpenFolderAndSelectItems(
    pidlFolder: *ItemIdList,
    cidl: u32,
    apidl: ?[*]const *ItemIdList,
    dwFlags: u32,
) callconv(.winapi) HRESULT;

pub const COINIT_APARTMENTTHREADED: u32 = 0x2;

pub extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;

/// Returns a fake HINSTANCE. Anything above 32 means the shell took it.
pub extern "shell32" fn ShellExecuteW(
    hwnd: ?HANDLE,
    lpOperation: ?[*:0]const u16,
    lpFile: [*:0]const u16,
    lpParameters: ?[*:0]const u16,
    lpDirectory: ?[*:0]const u16,
    nShowCmd: i32,
) callconv(.winapi) usize;

pub extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;

pub extern "advapi32" fn OpenProcessToken(
    ProcessHandle: HANDLE,
    DesiredAccess: DWORD,
    TokenHandle: *HANDLE,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn GetTokenInformation(
    TokenHandle: HANDLE,
    TokenInformationClass: i32,
    TokenInformation: ?*anyopaque,
    TokenInformationLength: DWORD,
    ReturnLength: *DWORD,
) callconv(.winapi) BOOL;

pub const TOKEN_QUERY: DWORD = 0x0008;
pub const TokenElevation: i32 = 20;

pub const SHCNE_ASSOCCHANGED: i32 = 0x0800_0000;
pub const SHCNF_IDLIST: u32 = 0;

pub extern "shell32" fn SHChangeNotify(
    wEventId: i32,
    uFlags: u32,
    dwItem1: ?*const anyopaque,
    dwItem2: ?*const anyopaque,
) callconv(.winapi) void;

// ---- the registry ----

pub const HKEY_CURRENT_USER: HANDLE = @ptrFromInt(0x8000_0001);
pub const KEY_WRITE: DWORD = 0x0002_0006;
pub const REG_SZ: DWORD = 1;
pub const ERROR_SUCCESS: i32 = 0;
pub const ERROR_FILE_NOT_FOUND: i32 = 2;

/// Creates every key along the path that is not there yet, and opens rather
/// than replaces one that is.
pub extern "advapi32" fn RegCreateKeyExW(
    hKey: HANDLE,
    lpSubKey: [*:0]const u16,
    Reserved: DWORD,
    lpClass: ?[*:0]const u16,
    dwOptions: DWORD,
    samDesired: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    phkResult: *HANDLE,
    lpdwDisposition: ?*DWORD,
) callconv(.winapi) i32;

/// A null name is the key's own unnamed value, which is the one the shell
/// reads for a verb's label and its command line.
pub extern "advapi32" fn RegSetValueExW(
    hKey: HANDLE,
    lpValueName: ?[*:0]const u16,
    Reserved: DWORD,
    dwType: DWORD,
    lpData: [*]const u8,
    cbData: DWORD,
) callconv(.winapi) i32;

/// Refuses a key that still has subkeys, which is what keeps a removal to the
/// keys it knows about.
pub extern "advapi32" fn RegDeleteKeyW(
    hKey: HANDLE,
    lpSubKey: [*:0]const u16,
) callconv(.winapi) i32;

pub extern "advapi32" fn RegCloseKey(hKey: HANDLE) callconv(.winapi) i32;

pub extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
pub extern "kernel32" fn AcquireSRWLockExclusive(SRWLock: *usize) callconv(.winapi) void;
pub extern "kernel32" fn ReleaseSRWLockExclusive(SRWLock: *usize) callconv(.winapi) void;

/// Slim reader/writer lock, exclusive only. SRWLOCK_INIT is a null pointer.
pub const Lock = struct {
    srw: usize = 0,

    pub fn acquire(self: *Lock) void {
        AcquireSRWLockExclusive(&self.srw);
    }

    pub fn release(self: *Lock) void {
        ReleaseSRWLockExclusive(&self.srw);
    }
};

pub extern "kernel32" fn SleepConditionVariableSRW(
    ConditionVariable: *usize,
    SRWLock: *usize,
    dwMilliseconds: DWORD,
    Flags: u32,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn WakeConditionVariable(ConditionVariable: *usize) callconv(.winapi) void;

pub const INFINITE: DWORD = 0xFFFF_FFFF;

/// Condition variable, paired with the lock above. Windows puts the two in the
/// same family: both start life as a null pointer and both are one word.
///
/// What a worker thread with nothing to do needs. Polling on a timer instead
/// would mean a thread waking up several times a second for the whole life of
/// the program to find the queue still empty.
pub const Signal = struct {
    cv: usize = 0,

    /// Releases `lock`, waits to be woken, and has the lock again on the way
    /// out. A wakeup with nothing behind it is allowed, which is why every
    /// caller checks its own condition in a loop.
    pub fn wait(self: *Signal, lock: *Lock) void {
        _ = SleepConditionVariableSRW(&self.cv, &lock.srw, INFINITE, 0);
    }

    pub fn wake(self: *Signal) void {
        WakeConditionVariable(&self.cv);
    }
};

// ---- named pipes ----

pub const ULONG = u32;

pub const SecurityAttributes = extern struct {
    nLength: DWORD = @sizeOf(SecurityAttributes),
    lpSecurityDescriptor: ?*anyopaque = null,
    bInheritHandle: BOOL = 0,
};

pub const PIPE_ACCESS_DUPLEX: DWORD = 0x0000_0003;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE: DWORD = 0x0008_0000;
pub const PIPE_TYPE_BYTE: DWORD = 0x0000_0000;
pub const PIPE_READMODE_BYTE: DWORD = 0x0000_0000;
pub const PIPE_WAIT: DWORD = 0x0000_0000;
pub const PIPE_REJECT_REMOTE_CLIENTS: DWORD = 0x0000_0008;
pub const FILE_WRITE_DATA: DWORD = 0x0000_0002;
pub const SECURITY_SQOS_PRESENT: DWORD = 0x0010_0000;
pub const SECURITY_IDENTIFICATION: DWORD = 0x0001_0000;

pub const ERROR_BROKEN_PIPE: DWORD = 109;
pub const ERROR_PIPE_BUSY: DWORD = 231;
pub const ERROR_NO_DATA: DWORD = 232;
pub const ERROR_PIPE_CONNECTED: DWORD = 535;
pub const ERROR_CANCELLED: DWORD = 1223;

pub extern "kernel32" fn CreateNamedPipeW(
    lpName: [*:0]const u16,
    dwOpenMode: DWORD,
    dwPipeMode: DWORD,
    nMaxInstances: DWORD,
    nOutBufferSize: DWORD,
    nInBufferSize: DWORD,
    nDefaultTimeOut: DWORD,
    lpSecurityAttributes: ?*const SecurityAttributes,
) callconv(.winapi) HANDLE;

pub extern "kernel32" fn ConnectNamedPipe(hNamedPipe: HANDLE, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitNamedPipeW(lpNamedPipeName: [*:0]const u16, nTimeOut: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetNamedPipeServerProcessId(Pipe: HANDLE, ServerProcessId: *ULONG) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
pub extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

pub extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    StringSecurityDescriptor: [*:0]const u16,
    StringSDRevision: DWORD,
    SecurityDescriptor: *?*anyopaque,
    SecurityDescriptorSize: ?*ULONG,
) callconv(.winapi) BOOL;

// ---- services ----

pub const SC_HANDLE = *anyopaque;
pub const SERVICE_STATUS_HANDLE = *anyopaque;

pub const SC_MANAGER_CONNECT: DWORD = 0x0001;
pub const SC_MANAGER_ALL_ACCESS: DWORD = 0x000F_003F;
pub const SERVICE_QUERY_STATUS: DWORD = 0x0004;
pub const SERVICE_ALL_ACCESS: DWORD = 0x000F_01FF;

pub const SERVICE_WIN32_OWN_PROCESS: DWORD = 0x0000_0010;
pub const SERVICE_AUTO_START: DWORD = 2;
pub const SERVICE_ERROR_NORMAL: DWORD = 1;
pub const SERVICE_NO_CHANGE: DWORD = 0xFFFF_FFFF;

pub const SERVICE_CONTROL_STOP: DWORD = 1;
pub const SERVICE_CONTROL_INTERROGATE: DWORD = 4;
pub const SERVICE_CONTROL_SHUTDOWN: DWORD = 5;
pub const SERVICE_ACCEPT_STOP: DWORD = 0x0001;
pub const SERVICE_ACCEPT_SHUTDOWN: DWORD = 0x0004;

pub const SERVICE_STOPPED: DWORD = 1;
pub const SERVICE_START_PENDING: DWORD = 2;
pub const SERVICE_STOP_PENDING: DWORD = 3;
pub const SERVICE_RUNNING: DWORD = 4;

pub const SC_STATUS_PROCESS_INFO: i32 = 0;
pub const SERVICE_CONFIG_DESCRIPTION: DWORD = 1;
pub const SERVICE_CONFIG_FAILURE_ACTIONS: DWORD = 2;
pub const SERVICE_CONFIG_REQUIRED_PRIVILEGES_INFO: DWORD = 6;
pub const SC_ACTION_RESTART: i32 = 1;

pub const NO_ERROR: DWORD = 0;
pub const ERROR_CALL_NOT_IMPLEMENTED: DWORD = 120;
pub const ERROR_SERVICE_ALREADY_RUNNING: DWORD = 1056;
pub const ERROR_SERVICE_DOES_NOT_EXIST: DWORD = 1060;
pub const ERROR_SERVICE_NOT_ACTIVE: DWORD = 1062;
pub const ERROR_FAILED_SERVICE_CONTROLLER_CONNECT: DWORD = 1063;
pub const ERROR_SERVICE_MARKED_FOR_DELETE: DWORD = 1072;

pub const ServiceStatus = extern struct {
    dwServiceType: DWORD = SERVICE_WIN32_OWN_PROCESS,
    dwCurrentState: DWORD = SERVICE_STOPPED,
    dwControlsAccepted: DWORD = 0,
    dwWin32ExitCode: DWORD = 0,
    dwServiceSpecificExitCode: DWORD = 0,
    dwCheckPoint: DWORD = 0,
    dwWaitHint: DWORD = 0,
};

pub const ServiceStatusProcess = extern struct {
    dwServiceType: DWORD = 0,
    dwCurrentState: DWORD = 0,
    dwControlsAccepted: DWORD = 0,
    dwWin32ExitCode: DWORD = 0,
    dwServiceSpecificExitCode: DWORD = 0,
    dwCheckPoint: DWORD = 0,
    dwWaitHint: DWORD = 0,
    dwProcessId: DWORD = 0,
    dwServiceFlags: DWORD = 0,
};

pub const ServiceMain = *const fn (argc: DWORD, argv: ?[*]?[*:0]u16) callconv(.winapi) void;

pub const ServiceTableEntry = extern struct {
    lpServiceName: ?[*:0]const u16,
    lpServiceProc: ?ServiceMain,
};

pub const ServiceDescription = extern struct {
    lpDescription: ?[*:0]const u16,
};

pub const ServiceRequiredPrivileges = extern struct {
    /// Names each ending in a null, with one more null after the last.
    pmszRequiredPrivileges: [*]const u16,
};

pub const ScAction = extern struct {
    Type: i32,
    Delay: DWORD,
};

pub const ServiceFailureActions = extern struct {
    dwResetPeriod: DWORD,
    lpRebootMsg: ?[*:0]const u16 = null,
    lpCommand: ?[*:0]const u16 = null,
    cActions: DWORD,
    lpsaActions: ?[*]const ScAction,
};

comptime {
    std.debug.assert(@sizeOf(ServiceStatusProcess) == 36);
    std.debug.assert(@sizeOf(ServiceFailureActions) == 40);
    std.debug.assert(@sizeOf(SecurityAttributes) == 24);
}

pub extern "advapi32" fn OpenSCManagerW(
    lpMachineName: ?[*:0]const u16,
    lpDatabaseName: ?[*:0]const u16,
    dwDesiredAccess: DWORD,
) callconv(.winapi) ?SC_HANDLE;

pub extern "advapi32" fn OpenServiceW(
    hSCManager: SC_HANDLE,
    lpServiceName: [*:0]const u16,
    dwDesiredAccess: DWORD,
) callconv(.winapi) ?SC_HANDLE;

pub extern "advapi32" fn CreateServiceW(
    hSCManager: SC_HANDLE,
    lpServiceName: [*:0]const u16,
    lpDisplayName: ?[*:0]const u16,
    dwDesiredAccess: DWORD,
    dwServiceType: DWORD,
    dwStartType: DWORD,
    dwErrorControl: DWORD,
    lpBinaryPathName: ?[*:0]const u16,
    lpLoadOrderGroup: ?[*:0]const u16,
    lpdwTagId: ?*DWORD,
    lpDependencies: ?[*:0]const u16,
    lpServiceStartName: ?[*:0]const u16,
    lpPassword: ?[*:0]const u16,
) callconv(.winapi) ?SC_HANDLE;

pub extern "advapi32" fn ChangeServiceConfigW(
    hService: SC_HANDLE,
    dwServiceType: DWORD,
    dwStartType: DWORD,
    dwErrorControl: DWORD,
    lpBinaryPathName: ?[*:0]const u16,
    lpLoadOrderGroup: ?[*:0]const u16,
    lpdwTagId: ?*DWORD,
    lpDependencies: ?[*:0]const u16,
    lpServiceStartName: ?[*:0]const u16,
    lpPassword: ?[*:0]const u16,
    lpDisplayName: ?[*:0]const u16,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn ChangeServiceConfig2W(
    hService: SC_HANDLE,
    dwInfoLevel: DWORD,
    lpInfo: ?*const anyopaque,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn StartServiceW(
    hService: SC_HANDLE,
    dwNumServiceArgs: DWORD,
    lpServiceArgVectors: ?[*]const [*:0]const u16,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn ControlService(
    hService: SC_HANDLE,
    dwControl: DWORD,
    lpServiceStatus: *ServiceStatus,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn QueryServiceStatusEx(
    hService: SC_HANDLE,
    InfoLevel: i32,
    lpBuffer: *ServiceStatusProcess,
    cbBufSize: DWORD,
    pcbBytesNeeded: *DWORD,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn DeleteService(hService: SC_HANDLE) callconv(.winapi) BOOL;
pub extern "advapi32" fn CloseServiceHandle(hSCObject: SC_HANDLE) callconv(.winapi) BOOL;

pub extern "advapi32" fn StartServiceCtrlDispatcherW(
    lpServiceStartTable: [*]const ServiceTableEntry,
) callconv(.winapi) BOOL;

pub const HandlerEx = *const fn (
    dwControl: DWORD,
    dwEventType: DWORD,
    lpEventData: ?*anyopaque,
    lpContext: ?*anyopaque,
) callconv(.winapi) DWORD;

pub extern "advapi32" fn RegisterServiceCtrlHandlerExW(
    lpServiceName: [*:0]const u16,
    lpHandlerProc: HandlerEx,
    lpContext: ?*anyopaque,
) callconv(.winapi) ?SERVICE_STATUS_HANDLE;

pub extern "advapi32" fn SetServiceStatus(
    hServiceStatus: SERVICE_STATUS_HANDLE,
    lpServiceStatus: *const ServiceStatus,
) callconv(.winapi) BOOL;

// ---- installing ----

pub extern "kernel32" fn CopyFileW(
    lpExistingFileName: [*:0]const u16,
    lpNewFileName: [*:0]const u16,
    bFailIfExists: BOOL,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn RemoveDirectoryW(lpPathName: [*:0]const u16) callconv(.winapi) BOOL;

pub const Guid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

/// {905e63b6-c1bf-494e-b29c-65b732d3d21a}
pub const FOLDERID_ProgramFiles: Guid = .{
    .data1 = 0x905e63b6,
    .data2 = 0xc1bf,
    .data3 = 0x494e,
    .data4 = .{ 0xb2, 0x9c, 0x65, 0xb7, 0x32, 0xd3, 0xd2, 0x1a },
};

pub extern "shell32" fn SHGetKnownFolderPath(
    rfid: *const Guid,
    dwFlags: DWORD,
    hToken: ?HANDLE,
    ppszPath: *?[*:0]u16,
) callconv(.winapi) HRESULT;

pub extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;

pub const SEE_MASK_NOCLOSEPROCESS: u32 = 0x0000_0040;
pub const SEE_MASK_NOASYNC: u32 = 0x0000_0100;
pub const SW_HIDE: i32 = 0;

pub const ShellExecuteInfo = extern struct {
    cbSize: DWORD = @sizeOf(ShellExecuteInfo),
    fMask: u32 = 0,
    hwnd: ?HANDLE = null,
    lpVerb: ?[*:0]const u16 = null,
    lpFile: ?[*:0]const u16 = null,
    lpParameters: ?[*:0]const u16 = null,
    lpDirectory: ?[*:0]const u16 = null,
    nShow: i32 = 0,
    hInstApp: ?HANDLE = null,
    lpIDList: ?*anyopaque = null,
    lpClass: ?[*:0]const u16 = null,
    hkeyClass: ?HANDLE = null,
    dwHotKey: DWORD = 0,
    hIconOrMonitor: ?HANDLE = null,
    hProcess: ?HANDLE = null,
};

comptime {
    std.debug.assert(@sizeOf(ShellExecuteInfo) == 112);
}

pub extern "shell32" fn ShellExecuteExW(pExecInfo: *ShellExecuteInfo) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;
