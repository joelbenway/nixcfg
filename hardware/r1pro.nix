{...}: {
  services.udev.extraRules = ''
    # Rule to set autosuspend after 5 min for VXE R1 PRO mouse (dongle and wire)
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="3554", ATTR{idProduct}=="f58a", TEST=="power/autosuspend_delay_ms", ATTR{power/autosuspend_delay_ms}="300000"
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="3554", ATTR{idProduct}=="f58c", TEST=="power/autosuspend_delay_ms", ATTR{power/autosuspend_delay_ms}="300000"
  '';
}
