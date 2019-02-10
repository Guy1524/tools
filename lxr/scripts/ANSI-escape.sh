#!/bin/bash

# ANSI escape sequences

CSI=$'\x1b[';	# CSI = esc [
VTbold="${CSI}1m";
VTnorm="${CSI}0m";
VTred="${VTbold}${CSI}31m";
VTyellow="${VTbold}${CSI}33m";
VTgreen="${VTbold}${CSI}32m";
