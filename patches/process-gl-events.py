#!/usr/bin/env python3
# Processes recent GitLab events to inform folks on the mailing list

import re
import time
import datetime
import pathlib

import dateutil.parser
import git
import gitlab

import cfg
import db_helper
import mail_helper

wine_repo = git.Repo(cfg.local_wine_git_path)
assert not wine_repo.bare
assert not wine_repo.is_dirty()
assert wine_repo.head.ref == wine_repo.heads.master
wine_git = wine_repo.git
# Ensure we are up to date
wine_git.fetch('upstream')
wine_git.merge('upstream/master')
# repo owner
gl = gitlab.Gitlab('http://localhost', private_token='KdpNodSToCXzsE5na-iB')
wine_gl = gl.projects.get(3)

#assumes that the remote of the source branch has been added
def find_mr_initial_hash(mr):
  source_project = gl.projects.get(mr.source_project_id)
  initial_hash = source_project.branches.get(mr.source_branch).commit['id']
  # get the events of the source project again
  for event in source_project.events.list(sort='asc'):
    if (dateutil.parser.parse(event.created_at) > dateutil.parser.parse(mr.created_at)) and event.action_name == 'pushed to':
      initial_hash = event.push_data['commit_from']
      break
  return initial_hash

# TODO: this function could use a lot of cleanup
# TODO: only send the commit that has been updated, not every single one
# TODO: instead of using native git facilities to get the formatted patches, we should probably use the gitlab API so that we don't have to create a branch in the user's repo
def process_mr_event(event, mr):
  print(mr.author)
  if (event.action_name == 'opened' or event.action_name == 'pushed to') and not mr.author['id'] == cfg.gl_bot_uid and not mr.work_in_progress:
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
    
    # If this is an opening event, and the MR has been updated since, we have problems
    top_hash = event.push_data['commit_to'] if event.action_name == 'pushed to' else find_mr_initial_hash(mr)

    # Add a branch referencing the top commit to ensure we can access this version
    source_project = gl.projects.get(mr.source_project_id)
    source_project.branches.create({'branch': 'temporary_scraper_branch', 'ref': top_hash})
    # Add the project as a remote
    wine_git.remote('add', 'mr_source', source_project.http_url_to_repo)
    wine_git.fetch('mr_source')

    # Format patches for submission
    wine_git.format_patch('origin..'+top_hash, subject_prefix=patch_prefix)

    # Remove the remote
    wine_git.remote('remove', 'mr_source')

    # Remove the branch
    source_project.branches.delete('temporary_scraper_branch')

    #send them
    for file_path in sorted(cfg.local_wine_git_path.iterdir()):
      if file_path.name.endswith('.patch'):
        # Create the discussion and the thread, then link them

        with file_path.open() as patch_file:
          contents = patch_file.read()

        search = re.search(r'^From (?P<commithash>\w*)', contents)
        assert search is not None
        commit_hash = search.group('commithash')
        assert commit_hash is not None
        patch_discussion = mr.discussions.create({'body': 'Discussion on commit ' + commit_hash})

        search = re.search(r'(?m)^Subject: (?P<subject>.*)$', contents)
        assert search is not None
        patch_subject = search.group('subject')
        assert patch_subject is not None
        patch_msg_id = mail_helper.send_mail(patch_subject, contents.split('\n\n', 1)[1], in_reply_to=msg_id)

        db_helper.link_discussion_to_mail(db_helper.Discussion(mr.id, patch_discussion.id), patch_msg_id)
    # Clean Up
    wine_git.reset('origin/master', hard=True)
    wine_git.clean(force=True)

  if event.action_name == 'closed' and mr.author['id'] == cfg.gl_bot_uid:
    # Send message notifying author the patchset has been closed
    print( 'notifying author' )

def process_comment_event(event):
  if event.noteable_type != 'Merge Request': return
  if event.target_type == 'Note':
    # Not part of a discussion, just find the root email for the MR
    mail_thread = db_helper.lookup_mail_thread(db_helper.Discussion(event.note['noteable_id'], 0))
    # Send mail
  if event.target_type == 'DiscussionNote':
    # Find the discussion
    return

def process_event(event):
  print('Processing Event: ')
  print(event)
  if event.target_type == 'MergeRequest' or (event.project_id != cfg.upstream_repo_id and event.action_name == 'pushed to'):
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

# also get push events from the repos used in MRs, as the gitlab API docs are wrong and we can't rely on MR update events
for mr in wine_gl.mergerequests.list():
  source_project = gl.projects.get(mr.source_project_id)
  # get the events
  for event in source_project.events.list(sort='asc'):
    if (event.action_name == 'pushed to' and event.push_data['ref'] == mr.source_branch and
        dateutil.parser.parse(event.created_at) > dateutil.parser.parse(mr.created_at)):
      # HACK: set target_id to the MR ID, we should probably use commit.merge_requests() instead
      event.target_id = mr.id
      # insert the event into all_events based on the event time
      all_events.append(event)

def sort_by_time(event):
  return dateutil.parser.parse(event.created_at)

all_events.sort(key=sort_by_time)

for event in all_events:
  event_time = dateutil.parser.parse(event.created_at)
  if event_time > last_time:
    process_event(event)
    last_time = event_time

last_time_file = open('.last-time', "wt")
last_time_file.write(last_time.isoformat())
last_time_file.close()
