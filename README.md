## Purpose
This script is intended to be used instead of PieSpy (https://github.com/mchelen/piespy) when it is impossible to have online bot to analyze chat traffic. So, it can just parse IRC logs and generate pictures. 
Realtime-like behavior can be achieved using cron or any other scheduling tool.

## Changelog
v0.01 Barely-working version

## Usage
./sdiag.pl <input-file.txt>
it outputs diagram to output.png in current directory.
All configuration is held inside code of the script in global variables and scattered. Feel free to fix this.

## Original work
Based on the idea and alghoritms in PieSpy IRC bot written in Java.
http://www.jibble.org/piespy/
There also Irssi script implementing same thing: http://pasky.or.cz/~pasky/dev/irssi/piespy/piespy.pl

## License
As original software is licensed under GPLv2, this script has same licensing.
