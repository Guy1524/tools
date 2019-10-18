#!/usr/bin/env python3
#
# Our DB maps mail to its top-level parent, and each parent to a) a merge request and b) one of the threads in that merge request
#
# the thread can either be the default one, a user-created thread, or an auto-generated thread for a patch

import sqlite3
import os
from collections import namedtuple

new_db = not os.path.isfile('./threads.db')

db_connection = sqlite3.connect('./threads.db')
db_cursor = db_connection.cursor()

if new_db:
  db_cursor.execute('CREATE TABLE threads (msg_id text, mr_id int, disc_id binary)')
  db_cursor.execute('CREATE TABLE children (child_id text, parent_id text)')
  db_cursor.execute('CREATE TABLE versions (mr_id int PRIMARY KEY, version int)')
  db_connection.commit()

Discussion = namedtuple('Discussion', 'mr_id disc_id')

def lookup_discussion(msg_id):
  db_cursor.execute('SELECT * FROM threads WHERE msg_id=?', (msg_id,))
  row = db_cursor.fetchone()
  return Discussion(row[1], row[2]) if row is not None else None

def lookup_mail_thread(discussion):
  db_cursor.execute('SELECT * FROM threads WHERE mr_id=? AND disc_id=?', (discussion.mr_id, discussion.disc_id))
  row = db_cursor.fetchone()
  return row[0] if row is not None else None

def link_discussion_to_mail(discussion, msg_id):
  db_cursor.execute('INSERT INTO threads VALUES(?,?,?)', (msg_id, discussion.mr_id, discussion.disc_id))
  db_connection.commit()

###

def get_root_msg_id(msg_id):
  db_cursor.execute('SELECT * FROM childen WHERE msg_id=?', (msg_id,))
  row = db_cursor.fetchone()
  return row[1] if row is not None else None

def add_child(parent_msg_id, child_msg_id):
  db_cusor.execute('INSERT INTO children VALUES(?,?)', parent_msg_id, child_msg_id)
  db_connection.commit()

###

def get_mr_version(mr_id):
  db_cursor.execute('SELECT * FROM versions WHERE mr_id=?', (mr_id,))
  row = db_cursor.fetchone()
  return row[1] if row is not None else None

def make_version_entry(mr_id):
  db_cursor.execute('INSERT INTO versions VALUES(?,1)', (mr_id,))
  db_connection.commit()

def set_mr_version(mr_id, version):
  db_cursor.execute('UPDATE versions SET version=? WHERE mr_id=?', (version, mr_id))
  db_connection.commit()
