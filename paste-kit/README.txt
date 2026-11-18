edb_toolkit v3.3.0-1-g91048dd (2026-11-17) - paste kit, 8 parts + finish.sh

On the server, as your own admin account (not enterprisedb), in a bash shell:

  1. Open part-01.sh on your laptop, select all, copy, paste into the terminal, press Enter.
     It ends with "part 1 of 8: OK". If it says DAMAGED, paste the same part again.
     (Or: save the text with an editor on the server and run: bash part-01.sh)
  2. Do the same for part-02.sh ... part-08.sh, in any order.
  3. Paste finish.sh last. It checks every part and the whole kit, then unpacks to ~/edb_kit/edb_toolkit.
  4. cd ~/edb_kit/edb_toolkit && sudo tools/install.sh

Notes
  - The kit holds only committed files from commit 91048dd; never your conf/site.env.
  - Pasting a part twice is harmless; it overwrites its own file.
  - To start clean after a failed attempt: rm -rf ~/edb_kit
  - Whole-kit checksum (sha256 of the archive): 783e53fdaa80a81dff336dad3fd346ed7ef84283cb3d9406ca412f7340a30de1
