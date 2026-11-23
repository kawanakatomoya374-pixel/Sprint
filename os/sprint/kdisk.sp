# kdisk: the kernel's disks. Every ATA disk found is tried as a SprintFS volume; the first that mounts becomes the root file system.
import ata
import sprintfs
import ksys

export let root = nil          # the mounted sprintfs.Fs, or nil
export let disks = []

export func mount_all():
    for d in ata.probe():
        disks.append(d)
        ksys.log("disk: " .. d.model .. ", " .. to_string(d.blocks() * 4096 // 1048576) .. " MiB")
        if root != nil:
            continue
        try:
            root = sprintfs.mount(d)
            ksys.log("sprintfs mounted from " .. d.model .. ": " .. to_string(len(root.listdir("/"))) .. " entries in /")
            if root.exists("/hello.txt"):
                ksys.log("/hello.txt: " .. root.read_file("/hello.txt").trim())
            root.write_file("/booted.txt", "written by the Sprint kernel through the ATA driver\n")
            root.sync()
            ksys.log("sprintfs: wrote /booted.txt and synced")
        catch e:
            ksys.log("disk " .. d.model .. " is not a SprintFS volume (" .. e.message .. ")")
