#!/usr/bin/env python3
from pathlib
from datetime

# paths
patches_path = pathlib.Path.home() / 'patches/'
local_wine_git_path =  pathlib.Path.home() / 'wine'

bot_name = 'Gitlab Bot'
bot_address = 'bot@localhost'
# Login information of the bot, matches git's sendemail.*
smtpServer = 'localhost'
smtpServerPort = 1025
smtpUser = None
smtpPass = None
smtpEncryption = None

# Address of the mailing list where patches are submitted
mailing_list_address = 'dereklesho52@Gmail.com'

# ID of the gitlab bot which submits mail
gl_bot_uid = 2

# ID of main repo
upstream_repo_id = 3
# ID of bot's fork
fork_repo_id = 4

# Time at which incomplete patchsets are considered stale
cutoff_time = datetime.datetime.now() - datetime.timedelta(minutes=15)
