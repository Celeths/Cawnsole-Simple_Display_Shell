# Cawnsole Simple Display Shell

<img src="./Assets/icon.png" width="75"/>

Quickly set the resolution, refresh rate, scale, VRR, & HDR through a minimal terminal based menu designed to just work.  

[![Patreon](./Assets/Patreon.svg)](https://patreon.com/ProCrow?utm_medium=clipboard_copy&utm_source=copyLink&utm_campaign=creatorshare_creator&utm_content=join_link)

<img src="./Assets/hero.png" width="350"/>

<hr>

| Dependencies |
| --- |
| dialog |
| kscreen-doctor |

**NOTE:** Simple Display Shell does not enable new features or display parameters, simple display shell only exposes existing parameters.

## Installation & Use
### Installation Steps

1. Download the latest Simple-Display-Shell.sh file from the releases.
2. Move the Simple-Display-Shell.sh file anywhere desired.
3. Run Simple-Display-Shell.sh however you please (does not work when ran with sudo privilege).

### Using Simple Display Shell

Using the keyboard or mouse select the desired list item.

Running Simple Display Shell will initially show a list of all detected active display outputs. After selecting a detected output you will be shown another list of supported settings/ parameters to change for the selected output. Each subsequent selection will guide you through changing each parameter you select. 

After making a change, there will be a ten second confirmation window to confirm changes. The confirmation window also revert the changes if the ten second timer is reached.

After the selected change is confirmed or cancelled, the script will automatically close. To make another change, run the script again.

*The script will timeout and close after 60 seconds if no inputs are made.*

<hr>

**Below are screenshots with the menu name**

#### Detected Outputs

**Main Menu**

<img src="./Assets/outputs.png" width="450"/>

#### Identified Parameters

**Parameters For Selected Output)**

<img src="./Assets/parameters.png" width="450"/>

<img src="./Assets/alt.png" width="450"/>

*(only detected parameters are shown)*

#### Identified Resolutions

**Resolutions For Selected Output**

<img src="./Assets/res.png" width="450"/>

##### Identified Refresh Rates

**Refresh Rates For Selected Resolution**

<img src="./Assets/rr.png" width="450"/>

#### Display Scaling

**Scaling Sizes For Selected Output**

<img src="./Assets/scale.png" width="450"/>

##### Custom Display Scale Input

**Manual Entry For Display Scale**

<img src="./Assets/scale-custom.png" width="450"/>

#### Variable Refresh Rate (VRR)

**Variable Refresh Rate Settings For Selected Output**

<img src="./Assets/vrr.png" width="450"/>

#### High Dynamic Range (HDR)

**High Dynamic Range Settings For Selected Output**

<img src="./Assets/hdr.png" width="450"/>

#### Confirm Changes

**Confirm Changes Timeout Failsafe**

<img src="./Assets/confirm.png" width="450"/>