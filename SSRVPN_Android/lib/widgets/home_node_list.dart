import 'package:flutter/material.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import 'liquid_glass.dart';
import 'node_list_tile.dart';

class HomeNodeList extends StatelessWidget {
  const HomeNodeList({
    super.key,
    required this.nodes,
    required this.latencyController,
    required this.expandedSubscriptionGroups,
    required this.selectedNode,
    required this.testingNodeName,
    required this.isConnecting,
    required this.isBatchTesting,
    required this.isConnected,
    required this.textColor,
    required this.subColor,
    required this.isDark,
    required this.onTestAllLatency,
    required this.onTestLatency,
    required this.onSelectNode,
    required this.onLongPressNode,
    required this.onEditNode,
    required this.onToggleSubscriptionGroup,
  });

  final List<ProxyNode> nodes;
  final HomeLatencyController latencyController;
  final Set<String> expandedSubscriptionGroups;
  final ProxyNode? selectedNode;
  final String? testingNodeName;
  final bool isConnecting;
  final bool isBatchTesting;
  final bool isConnected;
  final Color textColor;
  final Color subColor;
  final bool isDark;
  final VoidCallback onTestAllLatency;
  final ValueChanged<ProxyNode> onTestLatency;
  final ValueChanged<ProxyNode> onSelectNode;
  final ValueChanged<ProxyNode> onLongPressNode;
  final ValueChanged<ProxyNode> onEditNode;
  final void Function(String title, bool expanded) onToggleSubscriptionGroup;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildHeader(),
        Expanded(child: _buildBody(context)),
      ],
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Responsive.gap(16),
        Responsive.gap(4),
        Responsive.gap(16),
        Responsive.gap(4),
      ),
      child: Row(
        children: [
          Container(
            width: Responsive.wp(3),
            height: Responsive.hp(14),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          SizedBox(width: Responsive.gap(8)),
          Text(
            '全部节点',
            style: TextStyle(
              fontSize: Responsive.sp(15),
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
          SizedBox(width: Responsive.gap(6)),
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: Responsive.gap(7),
              vertical: Responsive.gap(2),
            ),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(alpha: 20 / 255),
              borderRadius: BorderRadius.circular(Responsive.radius(8)),
            ),
            child: Text(
              '${nodes.length}',
              style: TextStyle(
                fontSize: Responsive.sp(11),
                fontWeight: FontWeight.w600,
                color: AppTheme.primaryColor,
              ),
            ),
          ),
          const Spacer(),
          if (isBatchTesting)
            SizedBox(
              width: Responsive.icon(14),
              height: Responsive.icon(14),
              child: const CircularProgressIndicator(
                strokeWidth: 2,
                color: AppTheme.primaryColor,
              ),
            )
          else if (isConnected)
            _SmallButton(
              icon: Icons.speed,
              label: '测速',
              onTap: onTestAllLatency,
            ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (isConnecting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AppTheme.primaryColor,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '正在启动VPN核心...',
              style: TextStyle(fontSize: Responsive.sp(13), color: subColor),
            ),
          ],
        ),
      );
    }

    if (nodes.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 10 / 255),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.dns_outlined,
                size: 28,
                color: AppTheme.primaryColor.withValues(alpha: 100 / 255),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '暂无节点',
              style: TextStyle(
                fontSize: Responsive.sp(15),
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '请先在订阅页面添加订阅链接',
              style: TextStyle(fontSize: Responsive.sp(12), color: subColor),
            ),
          ],
        ),
      );
    }

    final rows = HomeNodeController.buildDisplayRows(
      nodes,
      expandedSubscriptionGroups,
    );
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        12,
        6,
        12,
        MediaQuery.of(context).padding.bottom + LiquidGlassNavBar.height + 20,
      ),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        final section = row.section;
        if (section != null) {
          final title = section.title!;
          final expanded = expandedSubscriptionGroups.contains(title);
          return _SubscriptionGroupHeader(
            title: title,
            count: section.nodes.length,
            expanded: expanded,
            textColor: textColor,
            subColor: subColor,
            isDark: isDark,
            onTap: () => onToggleSubscriptionGroup(title, expanded),
          );
        }
        return _buildNodeTile(row.node!);
      },
    );
  }

  Widget _buildNodeTile(ProxyNode node) {
    final latency = latencyController.latencyFor(node);
    final isTesting = testingNodeName == node.name;
    final isSelected = selectedNode?.name == node.name;
    final isTimeout = latency != null && (latency <= 0 || latency >= 65535);

    return NodeListTile(
      node: node,
      latency: latency,
      isTesting: isTesting,
      isSelected: isSelected,
      isTimeout: isTimeout,
      isConnected: isConnected,
      onTestLatency: () => onTestLatency(node),
      onTap: () => onSelectNode(node),
      onLongPress: () => onLongPressNode(node),
      onEdit: () => onEditNode(node),
      textColor: textColor,
      subColor: subColor,
      isDark: isDark,
    );
  }
}

class _SubscriptionGroupHeader extends StatelessWidget {
  const _SubscriptionGroupHeader({
    required this.title,
    required this.count,
    required this.expanded,
    required this.textColor,
    required this.subColor,
    required this.isDark,
    required this.onTap,
  });

  final String title;
  final int count;
  final bool expanded;
  final Color textColor;
  final Color subColor;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: Responsive.gap(6)),
      child: InkWell(
        borderRadius: BorderRadius.circular(Responsive.radius(10)),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: Responsive.gap(12),
            vertical: Responsive.gap(10),
          ),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkCard : AppTheme.lightBg,
            borderRadius: BorderRadius.circular(Responsive.radius(10)),
            border: Border.all(
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
            ),
          ),
          child: Row(
            children: [
              Icon(
                expanded
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_right_rounded,
                size: Responsive.icon(20),
                color: AppTheme.primaryColor,
              ),
              SizedBox(width: Responsive.gap(8)),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: Responsive.sp(13),
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
              ),
              SizedBox(width: Responsive.gap(8)),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: Responsive.sp(11),
                  fontWeight: FontWeight.w600,
                  color: subColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkCard : AppTheme.lightBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: AppTheme.primaryColor),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: Responsive.sp(11),
                fontWeight: FontWeight.w500,
                color: AppTheme.primaryColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
