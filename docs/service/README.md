# The service

Reading the master file table needs administrator rights. The service has them, so the search doesn't need them.

```
elephant --install-service
```

That asks for administrator rights once, copies `elephant-service.exe` into `Program Files\ElephantSearch`, and starts it with Windows. Run it again after an update to replace the copy.

```
elephant --uninstall-service
```

That stops it and removes it.

## What it does

When a search asks, the service reads the drives and sends back names, sizes and dates. It keeps nothing between requests. The index and the search stay in the program you opened, which runs as you.

If you already run as administrator, the search reads the drives itself and skips the service.

## Who can see what

The service runs as LocalSystem and answers anyone signed in to the computer. With it installed, any local user can list the name, size and date of every file on every NTFS drive, other people's included. They can't open those files though. On a computer shared by people who shouldn't see each other's file names, think about that before installing it.

The saved index holds the same names. It sits in `%LOCALAPPDATA%\ElephantSearch`, where any program running as you can read it.

Without the service, the index is saved in the profile of whoever ran as administrator. If you sign in as a standard user and type an administrator's password at the prompt, the index lands in the administrator's profile and your own runs won't find it. With the service, the index always stays in your profile.
