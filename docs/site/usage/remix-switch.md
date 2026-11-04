Boots an OS image from the card without writing the flash. Each `.RMX`
file in `/BRAIN/REMIXES/` is a raw OS image.

## Operation

BRAIN > REMIXES lists the `.RMX` files in order. The one whose name
matches the running image (case and spaces ignored) shows `RUNNING` at the
right. Press [YES] to be asked `BOOT <NAME>?`; [YES] again boots it
without writing the flash. After a switch, a `FLASHED` separator shows the
image that a power-cycle returns to.

The image you switch to need not carry this module: stock 1.40C itself is
a valid target.
