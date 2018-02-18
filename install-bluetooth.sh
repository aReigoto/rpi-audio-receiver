#!/bin/sh

apt install -y --no-install-recommends alsa-base alsa-utils bluealsa bluez python-gobject python-dbus

# Bluetooth settings
mv /etc/bluetooth/main.conf /etc/bluetooth/main.conf.orig
cat <<'EOF' > /etc/bluetooth/main.conf
[General]
Class = 0x200414
DiscoverableTimeout = 0
PairableTimeout = 0

[Policy]
AutoEnable=true
EOF

service bluetooth start
hciconfig hci0 piscan
hciconfig hci0 sspmode 1

# Bluetooth agent
cat <<'EOF' > /usr/local/bin/simple-agent.autotrust
#!/usr/bin/python

#Automatically authenticating bluez agent. Script modifications by Merlin Schumacher <mls@ct.de> for c't Magazin (www.ct.de)

from __future__ import absolute_import, print_function, unicode_literals

from optparse import OptionParser
import sys
import dbus
import dbus.service
import dbus.mainloop.glib
try:
  from gi.repository import GObject
except ImportError:
  import gobject as GObject

SERVICE_NAME = "org.bluez"
ADAPTER_INTERFACE = SERVICE_NAME + ".Adapter1"
DEVICE_INTERFACE = SERVICE_NAME + ".Device1"

def get_managed_objects():
    bus = dbus.SystemBus()
    manager = dbus.Interface(bus.get_object("org.bluez", "/"),
                "org.freedesktop.DBus.ObjectManager")
    return manager.GetManagedObjects()

def find_adapter(pattern=None):
    return find_adapter_in_objects(get_managed_objects(), pattern)

def find_adapter_in_objects(objects, pattern=None):
    bus = dbus.SystemBus()
    for path, ifaces in objects.iteritems():
        adapter = ifaces.get(ADAPTER_INTERFACE)
        if adapter is None:
            continue
        if not pattern or pattern == adapter["Address"] or \
                            path.endswith(pattern):
            obj = bus.get_object(SERVICE_NAME, path)
            return dbus.Interface(obj, ADAPTER_INTERFACE)
    raise Exception("Bluetooth adapter not found")

def find_device(device_address, adapter_pattern=None):
    return find_device_in_objects(get_managed_objects(), device_address,
                                adapter_pattern)

def find_device_in_objects(objects, device_address, adapter_pattern=None):
    bus = dbus.SystemBus()
    path_prefix = ""
    if adapter_pattern:
        adapter = find_adapter_in_objects(objects, adapter_pattern)
        path_prefix = adapter.object_path
    for path, ifaces in objects.iteritems():
        device = ifaces.get(DEVICE_INTERFACE)
        if device is None:
            continue
        if (device["Address"] == device_address and
                        path.startswith(path_prefix)):
            obj = bus.get_object(SERVICE_NAME, path)
            return dbus.Interface(obj, DEVICE_INTERFACE)

    raise Exception("Bluetooth device not found")



BUS_NAME = 'org.bluez'
AGENT_INTERFACE = 'org.bluez.Agent1'
AGENT_PATH = "/test/agent"

bus = None
device_obj = None
dev_path = None

def ask(prompt):
    try:
        return raw_input(prompt)
    except:
        return input(prompt)

def set_trusted(path):
    props = dbus.Interface(bus.get_object("org.bluez", path),
                    "org.freedesktop.DBus.Properties")
    props.Set("org.bluez.Device1", "Trusted", True)

def dev_connect(path):
    dev = dbus.Interface(bus.get_object("org.bluez", path),
                            "org.bluez.Device1")
    dev.Connect()

class Rejected(dbus.DBusException):
    _dbus_error_name = "org.bluez.Error.Rejected"

class Agent(dbus.service.Object):
    exit_on_release = True

    def set_exit_on_release(self, exit_on_release):
        self.exit_on_release = exit_on_release

    @dbus.service.method(AGENT_INTERFACE,
                    in_signature="", out_signature="")
    def Release(self):
        print("Release")
        if self.exit_on_release:
            mainloop.quit()

    @dbus.service.method(AGENT_INTERFACE,
                    in_signature="os", out_signature="")
    def AuthorizeService(self, device, uuid):
        print("AuthorizeService (%s, %s)" % (device, uuid))
        set_trusted(device)
        return

    @dbus.service.method(AGENT_INTERFACE,
                    in_signature="o", out_signature="s")
    def RequestPinCode(self, device):
        print("RequestPinCode (%s)" % (device))
        set_trusted(device)
        return "1234"

    @dbus.service.method(AGENT_INTERFACE,
                    in_signature="o", out_signature="u")
    def RequestPasskey(self, device):
        print("RequestPasskey (%s)" % (device))
        set_trusted(device)
        passkey = ask("Enter passkey: ")
        return dbus.UInt32(passkey)

    @dbus.service.method(AGENT_INTERFACE,
                    in_signature="ouq", out_signature="")
    def DisplayPasskey(self, device, passkey, entered):
        print("DisplayPasskey (%s, %06u entered %u)" %
                        (device, passkey, entered))

    @dbus.service.method(AGENT_INTERFACE,
                    in_signature="os", out_signature="")
    def DisplayPinCode(self, device, pincode):
        print("DisplayPinCode (%s, %s)" % (device, pincode))

    @dbus.service.method(AGENT_INTERFACE,
                    in_signature="ou", out_signature="")
    def RequestConfirmation(self, device, passkey):
        print("RequestConfirmation (%s, %06d)" % (device, passkey))
        set_trusted(device)
        return

    @dbus.service.method(AGENT_INTERFACE,
                    in_signature="o", out_signature="")
    def RequestAuthorization(self, device):
        print("RequestAuthorization (%s)" % (device))
        set_trusted(device)
        return

    @dbus.service.method(AGENT_INTERFACE,
                    in_signature="", out_signature="")
    def Cancel(self):
        print("Cancel")

def pair_reply():
    print("Device paired")
    set_trusted(dev_path)
    dev_connect(dev_path)
    mainloop.quit()

def pair_error(error):
    err_name = error.get_dbus_name()
    if err_name == "org.freedesktop.DBus.Error.NoReply" and device_obj:
        print("Timed out. Cancelling pairing")
        device_obj.CancelPairing()
    else:
        print("Creating device failed: %s" % (error))


    mainloop.quit()

if __name__ == '__main__':
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)

    bus = dbus.SystemBus()

    capability = "NoInputNoOutput"

    parser = OptionParser()
    parser.add_option("-i", "--adapter", action="store",
                    type="string",
                    dest="adapter_pattern",
                    default=None)
    parser.add_option("-c", "--capability", action="store",
                    type="string", dest="capability")
    parser.add_option("-t", "--timeout", action="store",
                    type="int", dest="timeout",
                    default=60000)
    (options, args) = parser.parse_args()
    if options.capability:
        capability  = options.capability

    path = "/test/agent"
    agent = Agent(bus, path)

    mainloop = GObject.MainLoop()

    obj = bus.get_object(BUS_NAME, "/org/bluez");
    manager = dbus.Interface(obj, "org.bluez.AgentManager1")
    manager.RegisterAgent(path, capability)

    print("Agent registered")

    if len(args) > 0 and args[0].startswith("hci"):
        options.adapter_pattern = args[0]
        del args[:1]

    if len(args) > 0:
        device = find_device(args[0],
                        options.adapter_pattern)
        dev_path = device.object_path
        agent.set_exit_on_release(False)
        device.Pair(reply_handler=pair_reply, error_handler=pair_error,
                                timeout=60000)
        device_obj = device
    else:
        manager.RequestDefaultAgent(path)

    mainloop.run()
EOF
chmod 755 /usr/local/bin/simple-agent.autotrust

cat <<'EOF' > /etc/systemd/system/bluetooth-agent.service
[Unit]
Description=Bluetooth Agent
Requires=bluetooth.service
After=bluetooth.target bluetooth.service

[Install]
WantedBy=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/simple-agent.autotrust
EOF

systemctl enable bluetooth-agent.service

# ALSA settings
sed -i.orig 's/^options snd-usb-audio index=-2$/#options snd-usb-audio index=-2/' /lib/modprobe.d/aliases.conf

# BlueALSA
mkdir -p /etc/systemd/system/bluealsa.service.d
cat <<'EOF' > /etc/systemd/system/bluealsa.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/bin/bluealsa --disable-hfp --disable-hsp
EOF

cat <<'EOF' > /etc/systemd/system/bluealsa-aplay.service
[Unit]
Description=BlueALSA player
Requires=bluealsa.service
After=bluealsa.service
Wants=bluetooth.target sound.target

[Service]
Type=simple
User=root
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/bluealsa-aplay --pcm-buffer-time=250000 00:00:00:00:00:00
Restart=on-failure

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable bluealsa-aplay

# Bluetooth udev script
cat <<'EOF' > /usr/local/bin/bluez-udev
#!/bin/bash
name=$(sed 's/\"//g' <<< $NAME)
if [[ ! $name =~ ^([0-9A-F]{2}[:-]){5}([0-9A-F]{2})$ ]]; then exit 0;  fi

bt_name=`grep Name /var/lib/bluetooth/*/$name/info | awk -F'=' '{print $2}'`

action=$(expr "$ACTION" : "\([a-zA-Z]\+\).*")
logger "Action: $action"

if [ "$action" = "add" ]; then
    logger "[$(basename $0)] Bluetooth device is being added [$name] - $bt_name"
    bluetoothctl << EOT
discoverable off
EOT
    #aplay -q /home/pi/Music/setup-complete.wav
    #ifconfig wlan0 down
fi

if [ "$action" = "remove" ]; then
    logger "[$(basename $0)] Bluetooth device is being removed [$name] - $bt_name"
    #ifconfig wlan0 up
    #aplay -q /home/pi/Music/setup-required.wav
    bluetoothctl << EOT
discoverable on
EOT
fi
EOF
chmod 755 /usr/local/bin/bluez-udev

cat <<'EOF' > /etc/udev/rules.d/99-input.rules
SUBSYSTEM=="input", GROUP="input", MODE="0660"
KERNEL=="input[0-9]*", RUN+="/usr/local/bin/bluez-udev"
EOF
