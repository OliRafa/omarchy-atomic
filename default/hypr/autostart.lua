hl.on("hyprland.start", function()
  -- Slow app launch fix -- set systemd vars before starting session services.
  hl.exec_cmd("systemctl --user import-environment $(env | cut -d'=' -f 1)")
  hl.exec_cmd("dbus-update-activation-environment --systemd --all")

  hl.exec_cmd("omarchy-launch-shell")

  -- Fedora Asahi has no disk encryption, so the boot password is entered at
  -- the shell lock instead, the way the pre-quattro hyprlock flow worked.
  -- The script polls the shell's IPC until the lock is up.
  hl.exec_cmd("omarchy-system-lock-boot")
  -- fcitx5 is launched and supervised by omarchy-fcitx5.service (see commit 6e07fd0e), NOT here.
  -- A direct launch owns org.fcitx.Fcitx5, so the unit's instance exits on arrival and thrashes
  -- into start-limit-hit ("Failed unit detected: omarchy-fcitx5.service"). This line was removed in
  -- 6e07fd0e and re-introduced by an upstream merge; do not add it back.
  hl.exec_cmd("omarchy-provision-first-run")
  hl.exec_cmd("omarchy-powerprofiles-init")
  hl.exec_cmd(o.launch("omarchy-hyprland-monitor-watch"))
  hl.exec_cmd(o.launch("udiskie --automount --no-notify --no-tray"))

  -- Run post-boot hooks after startup config has loaded.
  hl.exec_cmd("sleep 2 && omarchy-hook post-boot")
end)
