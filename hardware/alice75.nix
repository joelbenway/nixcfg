{...}: {
  services.udev.extraRules = ''
    # Rule to set autosuspend after 5 min for Feker Alice 75 keyboard
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="36b0", ATTR{idProduct}=="3002", TEST=="power/autosuspend_delay_ms", ATTR{power/autosuspend_delay_ms}="300000"
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="36b0", ATTR{idProduct}=="3016", TEST=="power/autosuspend_delay_ms", ATTR{power/autosuspend_delay_ms}="300000"
  '';
}
