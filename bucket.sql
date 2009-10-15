-- phpMyAdmin SQL Dump
-- version 2.11.6
-- http://www.phpmyadmin.net
--
-- Host: localhost
-- Generation Time: May 22, 2009 at 12:36 PM
-- Server version: 5.0.51
-- PHP Version: 5.2.6-3

SET SQL_MODE="NO_AUTO_VALUE_ON_ZERO";

--
-- Database: `xkcd`
--

-- --------------------------------------------------------

--
-- Table structure for table `band_names`
--

CREATE TABLE IF NOT EXISTS `band_names` (
  `id` int(10) unsigned NOT NULL auto_increment,
  `band` varchar(32) NOT NULL,
  PRIMARY KEY  (`id`),
  UNIQUE KEY `band` (`band`)
) ENGINE=MyISAM  DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `bucket_facts`
--

CREATE TABLE IF NOT EXISTS `bucket_facts` (
  `id` int(10) unsigned NOT NULL auto_increment,
  `fact` varchar(64) NOT NULL,
  `tidbit` text NOT NULL,
  `verb` varchar(16) NOT NULL default 'is',
  `RE` tinyint(1) NOT NULL,
  `protected` tinyint(1) NOT NULL,
  `mood` tinyint(3) unsigned default NULL,
  `chance` tinyint(3) unsigned default NULL,
  PRIMARY KEY  (`id`),
  UNIQUE KEY `fact` (`fact`,`tidbit`(200),`verb`),
  KEY `trigger` (`fact`),
  KEY `RE` (`RE`)
) ENGINE=MyISAM  DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `bucket_items`
--

CREATE TABLE IF NOT EXISTS `bucket_items` (
  `id` int(10) unsigned NOT NULL auto_increment,
  `channel` varchar(64) NOT NULL,
  `what` varchar(255) NOT NULL,
  `user` varchar(64) NOT NULL,
  PRIMARY KEY  (`id`),
  KEY `from` (`user`),
  KEY `where` (`channel`)
) ENGINE=MyISAM  DEFAULT CHARSET=latin1 ;

-- --------------------------------------------------------

--
-- Table structure for table `mainlog`
--

CREATE TABLE IF NOT EXISTS `mainlog` (
  `id` int(10) unsigned NOT NULL auto_increment,
  `stamp` timestamp NOT NULL default CURRENT_TIMESTAMP,
  `msg` varchar(512) NOT NULL,
  PRIMARY KEY  (`id`),
  KEY `stamp` (`stamp`)
) ENGINE=MyISAM  DEFAULT CHARSET=latin1;
