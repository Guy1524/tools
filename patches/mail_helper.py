#!/usr/bin/env python3
import ssl
import smtplib
import email
import cfg

ssl_ctx = ssl.create_default_context()
server = smtplib.SMTP(cfg.smtpServer, cfg.smtpServerPort)
if cfg.smtpEncryption == 'ssl' or cfg.smtpEncryption == 'tls':
  server.starttls(ssl_ctx)
if cfg.smtpUser:
  server.login(cfg.smtpUser, cfg.smtpPass if cfg.smtpPass is not None else '')

def send_mail(subject, body, in_reply_to=None):
  msg_id = email.utils.make_msgid()
  msg = email.message.EmailMessage()
  
  msg['Subject'] = subject
  msg['From'] = cfg.bot_name + ' <{0}>'.format(cfg.bot_address)
  msg['To'] = cfg.mailing_list_address
  msg['In-Reply-To'] = in_reply_to
  msg['Message-ID'] = msg_id
  
  msg.set_content(body)
  server.sendmail(cfg.bot_address, cfg.mailing_list_address, msg.as_string())
  return msg_id
