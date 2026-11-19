using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

internal static class WindowsRouterLauncher
{
    private static int Main(string[] args)
    {
        if (args.Length != 1)
            return 1;

        int jobError = JoinRouterJob();
        if (jobError != 0)
            return jobError;

        var startInfo = new ProcessStartInfo
        {
            FileName = args[0],
            Arguments = "router.mjs router.json",
            WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        try
        {
            using (Process router = Process.Start(startInfo))
            {
                router.WaitForExit();
                return router.ExitCode;
            }
        }
        catch (Win32Exception error)
        {
            return error.NativeErrorCode;
        }
    }

    private const int ExtendedLimitInformation = 9;
    private const uint KillOnJobClose = 0x00002000;

    private static int JoinRouterJob()
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero)
            return Marshal.GetLastWin32Error();

        var limits = new JobLimits();
        limits.BasicLimits.LimitFlags = KillOnJobClose;
        if (!SetInformationJobObject(job, ExtendedLimitInformation, ref limits, Marshal.SizeOf(typeof(JobLimits))) ||
            !AssignProcessToJobObject(job, GetCurrentProcess()))
            return Marshal.GetLastWin32Error();

        // Keep the job handle open until Windows ends the launcher. Its Node child
        // inherits the job, so stopping the scheduled task also stops the router.
        return 0;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobLimits
    {
        public BasicJobLimits BasicLimits;
        public IoCounters Io;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicJobLimits
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int informationClass, ref JobLimits limits, int size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();
}
