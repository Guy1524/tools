#!/usr/bin/env python3
# Reads emails generated by the filter script and submits patches/make comments

import os
import re
import time
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
gl = gitlab.Gitlab.from_config(cfg.bot_login_cfg_name, [])
assert gl is not None
fork_gl = gl.projects.get(cfg.fork_repo_id)
assert fork_gl is not None
wine_gl = gl.projects.get(cfg.upstream_repo_id)
assert wine_gl is not None

# Utility functions
def is_full(array):
  for element in array:
    if element is None:
      return False
  return True

# End Utility Functions

Patch = namedtuple('Patch', 'path msgid subject')

def create_or_update_merge_request(mr, title, author, description, patches, prologue_msg_id):
  # create the local git branch
  branch_name = None
  if mr is None:
    branch_name = 'ml-patchset-{0}'.format(time.time())
    wine_git.checkout('HEAD', b=branch_name)
  else:
    branch_name = mr.source_branch
    wine_git.checkout(branch_name)
    wine_git.reset('master', hard=True)

  # apply the patches
  try:
    for patch in patches:
      wine_git.am(str(patch.path))
  except:
    print('Failed to apply patches, discarding patchset')
    # TODO: make more robust, and send email back if it didn't apply
    if mr:
      wine_git.reset('origin/'+branch_name, hard=True)
    wine_git.checkout('master')
    if mr is None:
      wine_git.branch(D=branch_name)
    return
  finally:
    for patch in patches:
      patch.path.unlink()

  wine_git.checkout('master')

  # push work to origin
  wine_git.push('origin', branch_name, force=True)

  # create merge request
  if mr is None:
    mr = fork_gl.mergerequests.create({'source_branch': branch_name,
                                       'target_project_id': cfg.upstream_repo_id,
                                       'target_branch': 'master',
                                       'title': patchset_title if patchset_title is not None else 'Multi-Patch Patchset from Mailing List',
                                       'description': description})
    # send email to wine-devel as a place to put MR comments 
    if prologue_msg_id is None:
      if len(patches) == 1:
        db_helper.link_discussion_to_mail(db_helper.Discussion(mr.id, 0), patches[0].msgid)
        return
      # send meta email if prologue wasn't sent
      mail_helper.send_mail('Gitlab discussion thread for recent patchset by' + author,
                            'Merge-Request Link: ' + mr.web_url)
    else:
      db_helper.link_discussion_to_mail(db_helper.Discussion(mr.id, 0), prologue_msg_id)
  elif prologue_msg_id and len(patches) != 1:
    extra_discussion = mr.discussions.create({'body': 'Discussion on updated commits'})
    db_helper.link_discussions_to_mail(db_helper.Discussion(mr.id, extra_discussion.id), prologue_msg_id)

  # create a discussion for each patch
  for patch in patches:
    patch_discussion = mr.discussions.create({'body': 'Discussion for {0}'.format(patch.subject)})
    # link mail thread to discussion
    db_helper.link_discussion_to_mail(db_helper.Discussion(mr.id, patch_discussion.id), patch.msgid)

Mail = namedtuple('Mail', 'msg_id reply_to sender body')

def format_email_body(raw_body):
  # for now, just put the entire email in a code block to prevent markdown formatting on patches
  # TODO: detect patches and put them in codeblocks, with the right language set
  return '```\n' + raw_body + '\n```'

# if it's not a patch, see if it's a comment on a MR thread
def process_standard_mail(mail):
  root_msg = db_helper.get_root_msg_id(mail.reply_to)
  discussion_entry = db_helper.lookup_discussion(root_msg)
  if discussion_entry is None:
    print(mail.reply_to, root_msg)
    return
  db_helper.add_child(root_msg, mail.msg_id)
  # TODO: Handle fancy emails
  comment_body = 'Mail from {0} on wine-devel:\n\n{1}'.format(mail.sender, format_email_body(mail.body))
  print(comment_body)
  mr = wine_gl.mergerequests.get(discussion_entry.mr_id)
  # get the discussion id, if present
  discussion = mr.discussions.get(discussion_entry.disc_id) if discussion_entry.disc_id != 0 else None
  if discussion is None:
    mr.notes.create({'body': comment_body})
  else:
    discussion.notes.create({'body': comment_body})

def find_root_mr(author_email, title):
  for mr in wine_gl.mergerequests.list(all=True):
    if mr.commits().next().author_email == author_email and mr.title == title:
      return mr
  return None

out_of_patches = False
processed_patch_files = []
while not out_of_patches:
  patches = None
  prologue_msg_id = None
  patchset_title = None # Set to subject of either PATCH[0/n], or PATCH[1/1]
  patchset_description = '' # If PATCH 0 exists, set the content of the email to the patchset description.  Right now filter doesn't provide us with this
  current_author = None
  mr = None
  out_of_patches = True
  for file_path in cfg.patches_path.iterdir():
    # discard if we've reached timeout
    create_time = datetime.datetime.fromtimestamp(os.path.getctime(file_path))
    if create_time < cfg.cutoff_time:
      file_path.unlink()
      continue

    if file_path.name in processed_patch_files:
      continue
    out_of_patches = False

    with file_path.open() as file:
      mail_contents = file.read()

    author = None
    email = None
    subject = None
    msg_id = None
    reply_to = None
    try:
      author   = re.search(r'(?m)^From: (.*)$', mail_contents).group(1)
      subject  = re.search(r'(?m)^Subject: (.*)$', mail_contents).group(1)
      msg_id   = re.search(r'(?m)^Message-Id: (.*)$', mail_contents).group(1)
    except:
      print('Invalid Message')
      file_path.unlink()
      continue
    search = re.search(r'(?m)^In-Reply-To: (.*)$', mail_contents)
    reply_to = search.group(1) if search is not None else None

    patch_prefix = re.search(r'^\[PATCH(?: v(?P<version>\d+))?(?: (?P<patch_idx>\d+)/(?P<patch_total>\d+))?\]', subject)
    author_search = re.search(r'^\"?(?P<name>[^\"]*)\"? <(?P<email>[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+)>$', author)
    email = author_search.group('email') if author_search is not None else None

    if email is None:
      file_path.unlink()
      continue

    if patch_prefix is None:
      process_standard_mail(Mail(msg_id, reply_to, author, mail_contents[mail_contents.find('\n\n'):]))
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

    if patch_total is None:
      patch_total = 1
      patch_idx = 1
      patchset_title = subject[patch_prefix.end() + 1:]

    patch_idx = int(patch_idx)
    patch_total = int(patch_total)

    if version is not None and version != 1 and patch_idx == 1:
      # Right now we only use patch 1 data to find the MR
      mr = find_root_mr(email, subject[patch_prefix.end() + 1:])
      if mr is None:
        print('unable to find MR for versioned patch')
        file_path.unlink()
        continue

    if patch_total < patch_idx:
      file_path.unlink()
      continue

    if patches is None:
      patches = [None] * patch_total
    elif len(patches) != patch_total:
      continue

    current_author = author
    processed_patch_files.append(file_path.name)

    if patch_idx == 0:
      patchset_title = subject[patch_prefix.end() + 1:]
      prologue_message_id = msg_id
      continue

    patches[patch_idx - 1] = Patch(file_path, msg_id, subject)

    if is_full(patches):
      create_or_update_merge_request(mr, patchset_title, current_author, patchset_description, patches, prologue_msg_id)
      break
