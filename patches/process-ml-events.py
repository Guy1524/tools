#!/usr/bin/env python3
# Reads emails generated by the filter script and submits patches/make comments

import os
import re
import time
import pathlib
import datetime
from collections import namedtuple

import git
import gitlab

import cfg
import db_helper
import mail_helper

# Do some initialization early so we can abort in case of failure
wine_repo = git.Repo(cfg.local_wine_git_path)
assert not wine_repo.bare
assert not wine_repo.is_dirty()
assert wine_repo.head.ref == wine_repo.heads.master
wine_git = wine_repo.git
# Ensure we are up to date
wine_git.fetch('upstream')
wine_git.merge('upstream/master')
gl = gitlab.Gitlab('http://localhost', private_token='DJAm88vRYLC4uTq_WXM4')
wine_gl = gl.projects.get(cfg.fork_repo_id)

# Utility functions
def is_full(array):
  for element in array:
    if element == None:
      return False
  return True

# End Utility Functions

Patch = namedtuple('Patch', 'path msgid subject')

def create_merge_request(title, author, description, patches, prologue_msg_id):
  # create the local git branch
  branch_name = 'ml-patchset-{0}'.format(time.time())
  wine_git.checkout('HEAD', b=branch_name)

  # apply the patches
  try:
    for patch in patches:
      wine_git.am(str(patch.path))
  except Exception:
    print('Failed to apply patches, discarding patchset')
    # TODO: make more robust, and send email back if it didn't apply
    wine_git.checkout('master')
    wine_git.branch(D=branch_name)
    return
  finally:
    for patch in patches:
      patch.path.unlink()

  wine_git.checkout('master');

  # push work to origin
  wine_git.push('origin', branch_name)

  # create merge request
  mr = wine_gl.mergerequests.create({'source_branch': branch_name,
                                     'target_project_id': cfg.upstream_repo_id,
                                     'target_branch': 'master',
                                     'title': patchset_title if patchset_title != None else 'Multi-Patch Patchset from Mailing List',
                                     'description': description})

  # TODO: send email to wine-devel as a place to put MR comments 
  if prologue_msg_id is None:
    if len(patches == 1):
      db_helper.link_discussion_to_mail(patches[0].msg_id, db_helper.Discussion(mr.id, 0))
      return
    # send meta email if prologue wasn't sent
    mail_helper.send_mail('Gitlab discussion thread for recent patchset by' + author,
      'Merge-Request Link: ' + mr.web_url,
    )
  else:
    db_helper.link_discussion_to_mail(db_helper.Discussion(mr.id, 0), prologue_msg_id)

  # create a discussion for each patch
  for patch in patches:
    patch_discussion = mr.discussions.create({'body': 'Discussion for {0}'.format(patch.subject)})
    # link mail thread to discussion
    db_helper.link_discussion_to_mail(patch.msgid, db_helper.Discussion(mr.id, patch_discussion.id))

Mail = namedtuple('Mail', 'msg_id sender body')

# if it's not a patch, see if it's a comment on a MR thread
def process_standard_mail(mail):
  root_msg = get_root_msg_id(mail.msg_id)
  if root_msg is None: return
  # TODO: Handle fancy emails
  comment_body = 'Sent by {0} on wine-devel\n\n{1}'.format(mail.sender, mail.body)
  print(comment_body)
  thread = lookup_discussion(mail.msg_id)
  mr = wine_gl.mergerequests.get(thread.mr_id)
  # get the discussion id, if present
  discussion = mr.discussions.get(thread.disc_id) if thread.disc_id != 0 else None
  if discussion is None:
    mr.notes.create({'body': comment_body})
  else:
    discussion.notes.create({'body': comment_body})

out_of_patches = False
processed_patch_files = []
while not out_of_patches:
  patches = None
  prologue_msg_id = None
  patchset_title = None # Set to subject of either PATCH[0/n], or PATCH[1/1]
  patchset_description = '' # If PATCH 0 exists, set the content of the email to the patchset description.  Right now filter doesn't provide us with this
  current_author = None
  out_of_patches = True
  found_complete_patch = False
  for file_path in cfg.patches_path.iterdir():
    # discard if we've reached timeout
    create_time = datetime.datetime.fromtimestamp(os.path.getctime(file_path))
    if create_time < cfg.cutoff_time:
      file_path.unlink()
      continue

    if file_path.name in processed_patch_files:
      continue
    out_of_patches = False

    with file_path.open() as file
      mail_contents = file.readlines()

    author = None
    subject = None
    msg_id = None
    for line in mail_contents:
      if line.startswith('From: '):
        author = line[6:-1]
      elif line.startswith('Subject: '):
        subject = line[9:-1]
      elif line.startswith('Message-Id: '):
        msg_id = line[12:-1]
    patch_prefix = re.search(r'^\[PATCH(?: v(?P<version>\d+))?(?: (?P<patch_idx>\d+)/(?P<patch_total>\d+))?\]', subject)

    if patch_prefix is None:
      process_standard_mail(Mail(msg_id, author, mail_contents[mail_contents.find('\n\n'):]))
      file_path.unlink()
      continue

    if 'resend' in patch_prefix.group(0):
      file_path.unlink()
      continue

    if current_author is not None and author != current_author:
      continue

    version = patch_prefix.group('version')
    patch_idx = patch_prefix.group('patch_idx')
    patch_total = patch_prefix.group('patch_total')

    if version is not None and version != 1:
      print('Can not handle updated patchsets yet')
      file_path.unlink()
      continue

    if patch_total is None:
      patch_total = 1
      patch_idx = 1
      patchset_title = subject[patch_prefix.end() + 1:]

    patch_idx = int(patch_idx)
    patch_total = int(patch_total)

    if patch_total < patch_idx:
      file_path.unlink()
      continue  

    if patches is None:
      patches = [None] * patch_total
    elif len(patches) != patch_total:
      continue

    current_author = author
    processed_patch_files.append(file_name)

    if patch_idx == 0:
      patchset_title = subject[patch_prefix.end() + 1:]
      prologue_message_id = msg_id
      continue

    patches[patch_idx - 1] = Patch(file_path, msg_id, subject)

    if is_full(patches):
      create_merge_request(patchset_title, current_author, patchset_description, patches, prologue_msg_id)
      break
