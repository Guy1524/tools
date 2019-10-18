#!/usr/bin/env python3
# Processes recent GitLab events to inform folks on the mailing list

import os
import re
import gitlab
import time
import datetime
import dateutil.parser
from git import Repo
import urllib.request
from email.message import EmailMessage
import email.utils
from collections import namedtuple
import cfg

import mail_helper

import db_helper

wine_repo = Repo(cfg.local_wine_git_path)
assert not wine_repo.bare
assert not wine_repo.is_dirty()
assert wine_repo.head.ref == wine_repo.heads.master
wine_git = wine_repo.git
# repo owner
gl = gitlab.Gitlab('http://localhost', private_token='KdpNodSToCXzsE5na-iB')
wine_gl = gl.projects.get(3)
# TODO: sync w/ upstream

def process_mr_event(event, mr):
  print(mr.author)
  if (event.action_name == 'opened' or event.action_name == 'update') and not mr.author['id'] == cfg.gl_bot_uid and not mr.work_in_progress:
    # Forward merge request as patchset to mailing list when it is created or updated
    print( 'updating ML' )
    # Lookup the merge request to get info about how to send it to the ML
    primary_discussion = db_helper.Discussion(mr.id, 0)
    msg_id = db_helper.lookup_mail_thread(primary_discussion)
    version = None
    if msg_id is None:
      # This means we haven't already sent a version of this MR to the mailing list, so we send the header and setup the row
      # TODO: if the MR only has one patch, batch up the MR description w/ the commit description and use that as the header
      msg_id = mail_helper.send_mail(mr.title, mr.description + '\n\nMerge-Request Link: ' + mr.web_url)
      db_helper.link_discussion_to_mail(primary_discussion, msg_id)
      db_helper.make_version_entry(mr.id)
      version = 1
    else:
      version = db_helper.get_mr_version(mr.id) + 1
      db_helper.set_mr_version(mr.id, version)
    patch_prefix = 'PATCH v' + str(version) if version != 1 else 'PATCH'
    # Download the patch/set
    tmp_patch = cfg.local_wine_git_path + '/tmp.patch'
    urllib.request.urlretrieve(mr.web_url + '.patch', tmp_patch)
    # Apply it locally
    wine_git.am(tmp_patch)
    os.remove(tmp_patch)
    # Format it for submission
    wine_git.format_patch('origin', subject_prefix=patch_prefix)
    for filename in os.listdir(cfg.local_wine_git_path):
      if filename.endswith('.patch'):
        # Create the discussion and the thread, then link them

        patch_file = open(cfg.local_wine_git_path + '/' + filename)
        contents = ''
        for line in patch_file.readlines():
          contents += line
        patch_file.close()

        search = re.search(r'^From (?P<commithash>\w*)', contents)
        assert search is not None
        commit_hash = search.group('commithash')
        assert commit_hash is not None
        patch_discussion = mr.discussions.create({'body': 'Discussion on commit ' + commit_hash}) # <- fix this, incorrect

        search = re.search(r'(?m)^Subject: (?P<subject>.*)$', contents)
        assert search is not None
        patch_subject = search.group('subject')
        assert patch_subject is not None
        patch_msg_id = mail_helper.send_mail(patch_subject, contents.split('\n\n', 1)[1],in_reply_to=msg_id)

        db_helper.link_discussion_to_mail(db_helper.Discussion(mr.id, patch_discussion.id), patch_msg_id)
    # Clean Up
    wine_git.reset('origin/master', hard=True)
    #wine_git.clean(f=True)
  
  if event.action_name == 'closed' and mr.author['id'] == ml_bot_uid:
    # Send message notifying author the patchset has been closed
    print( 'notifying author' )

def process_comment_event(event):
  if event.noteable_type != 'Merge Request': return
  if event.target_type == 'Note':
    # Not part of a discussion, just find the root email for the MR
    mail_thread = lookup_mail_thread(Discussion(event.note['noteable_id'], 0))
    # Send mail
  if event.target_type == 'DiscussionNote':
    # Find the discussion
    return

def process_event(event):
  print('Processing Event: ')
  print(event)
  if event.target_type == 'MergeRequest':
    mr = wine_gl.mergerequests.get(event.target_id)
    process_mr_event(event, mr)
  if event.action_name == 'commented on':
    print( 'Processing Comment' )
    print(wine_gl.mergerequests.get(event.note['noteable_id']).notes.get(event.target_id))
  return

# find the time of the most recent event we have processed
last_time_file = open('.last-time', "rt+")
last_time_iso = last_time_file.read()
last_time_file.close()
print(last_time_iso)
if last_time_iso == '':
  last_time = datetime.datetime.now(datetime.timezone.utc)
else:
  last_time = dateutil.parser.parse(last_time_iso)

print(last_time)

# get all events from both yesterday and today, so we don't miss any at the end of the day
two_days_ago = datetime.date.fromtimestamp(time.time()) - datetime.timedelta(days=2)
all_events = wine_gl.events.list(sort='asc')
#after=two_days_ago.isoformat(), 

print (all_events)
for event in all_events:
  event_time = dateutil.parser.parse(event.created_at)
  if event_time > last_time:
    process_event(event)
    last_time = event_time

last_time_file = open('.last-time', "wt")
last_time_file.write(last_time.isoformat())
last_time_file.close()
