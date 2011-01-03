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
-- Table structure for table `bucket_facts`
--

CREATE TABLE IF NOT EXISTS `bucket_facts` (
  `id` int(10) unsigned NOT NULL auto_increment,
  `fact` varchar(128) NOT NULL,
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
  UNIQUE KEY `what` (`what`),
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

-- --------------------------------------------------------

--
-- Table structure for table `bucket_values`
--

CREATE TABLE IF NOT EXISTS `bucket_values` (
  `id` int(10) unsigned NOT NULL auto_increment,
  `var_id` int(10) unsigned NOT NULL,
  `value` varchar(32) NOT NULL,
  PRIMARY KEY  (`id`),
  UNIQUE KEY `var_id` (`var_id`,`value`)
) ENGINE=MyISAM  DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Table structure for table `bucket_vars`
--

CREATE TABLE IF NOT EXISTS `bucket_vars` (
  `id` int(10) unsigned NOT NULL auto_increment,
  `name` varchar(16) NOT NULL,
  `perms` enum('read-only','editable') NOT NULL default 'read-only',
  `type` enum('var','varb','noun') NOT NULL default 'var',
  PRIMARY KEY  (`id`),
  UNIQUE KEY `name` (`name`)
) ENGINE=MyISAM  DEFAULT CHARSET=latin1;

--
-- Table structure for table `genders`
--

CREATE TABLE IF NOT EXISTS `genders` (
  `id` int(10) unsigned NOT NULL auto_increment,
  `nick` varchar(30) NOT NULL,
  `gender` enum('male','female','Androgynous','inanimate','full name') NOT NULL default 'Androgynous',
  `stamp` timestamp NOT NULL default CURRENT_TIMESTAMP,
  PRIMARY KEY  (`id`),
  UNIQUE KEY `nick` (`nick`)
) ENGINE=MyISAM  DEFAULT CHARSET=latin1;

--
-- Table structure for table `word2id`
--

DROP TABLE IF EXISTS `word2id`;
CREATE TABLE IF NOT EXISTS `word2id` (
  `id` int(10) unsigned NOT NULL auto_increment,
  `word` varchar(32) NOT NULL,
  `lines` int(10) unsigned NOT NULL,
  PRIMARY KEY  (`id`),
  UNIQUE KEY `word` (`word`)
) ENGINE=MyISAM  DEFAULT CHARSET=latin1;

--
-- Table structure for table `word2line`
--

DROP TABLE IF EXISTS `word2line`;
CREATE TABLE IF NOT EXISTS `word2line` (
  `word` int(10) unsigned NOT NULL,
  `line` int(10) unsigned NOT NULL,
  KEY `word` (`word`,`line`)
) ENGINE=MyISAM DEFAULT CHARSET=latin1;

