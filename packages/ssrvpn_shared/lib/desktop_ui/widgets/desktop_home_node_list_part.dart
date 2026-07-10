part of desktop_home_screen;

class _DesktopHomeNodeList extends StatelessWidget {
  const _DesktopHomeNodeList({
    required this.nodes,
    required this.latencyController,
    required this.exitCountryCodes,
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
    required this.onSecondaryTapDown,
    required this.onToggleSubscriptionGroup,
  });

  final List<ProxyNode> nodes;
  final HomeLatencyController latencyController;
  final Map<String, String> exitCountryCodes;
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
  final void Function(ProxyNode node, TapDownDetails details)
      onSecondaryTapDown;
  final void Function(String title, bool expanded) onToggleSubscriptionGroup;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildHeader(),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 10, 28, 8),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 16,
            decoration: BoxDecoration(
              color: AppTheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '全部节点',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 15 / 255),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppTheme.primary.withValues(alpha: 25 / 255),
              ),
            ),
            child: Text(
              '${nodes.length}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppTheme.primary,
              ),
            ),
          ),
          const Spacer(),
          if (isBatchTesting)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppTheme.primary,
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

  Widget _buildBody() {
    if (isConnecting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AppTheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text('正在启动核心...', style: TextStyle(fontSize: 14, color: subColor)),
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
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 10 / 255),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.dns_outlined,
                size: 32,
                color: AppTheme.primary.withValues(alpha: 100 / 255),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '暂无节点',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '请先在订阅页面添加订阅链接',
              style: TextStyle(fontSize: 13, color: subColor),
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
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
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
        return _buildNodeCard(row.node!);
      },
    );
  }

  Widget _buildNodeCard(ProxyNode node) {
    final latency = latencyController.latencyFor(node);
    final isTesting = testingNodeName == node.name;
    final isSelected = selectedNode?.name == node.name;
    final isTimeout = latency != null && (latency <= 0 || latency >= 65535);
    final countryCode =
        exitCountryCodes[node.name] ?? countryCodeForProxyNode(node);

    return _NodeCard(
      node: node,
      countryCode: countryCode,
      latency: latency,
      isTesting: isTesting,
      isSelected: isSelected,
      isTimeout: isTimeout,
      isConnected: isConnected,
      onTestLatency: () => onTestLatency(node),
      onTap: () => onSelectNode(node),
      onSecondaryTapDown: (details) => onSecondaryTapDown(node, details),
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
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.card : AppTheme.lightBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isDark ? AppTheme.border : AppTheme.lightBorder,
            ),
          ),
          child: Row(
            children: [
              Icon(
                expanded
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_right_rounded,
                size: 20,
                color: AppTheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.card : AppTheme.lightBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isDark ? AppTheme.border : AppTheme.lightBorder,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: AppTheme.primary),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppTheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NodeCard extends StatelessWidget {
  const _NodeCard({
    required this.node,
    required this.countryCode,
    required this.latency,
    required this.isTesting,
    required this.isSelected,
    required this.isTimeout,
    required this.isConnected,
    required this.onTestLatency,
    required this.onTap,
    required this.onSecondaryTapDown,
    required this.textColor,
    required this.subColor,
    required this.isDark,
  });

  final ProxyNode node;
  final String countryCode;
  final int? latency;
  final bool isTesting;
  final bool isSelected;
  final bool isTimeout;
  final bool isConnected;
  final VoidCallback onTestLatency;
  final VoidCallback onTap;
  final GestureTapDownCallback onSecondaryTapDown;
  final Color textColor;
  final Color subColor;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final effectiveTextColor =
        isTimeout ? textColor.withValues(alpha: 80 / 255) : textColor;
    final effectiveSubColor =
        isTimeout ? subColor.withValues(alpha: 60 / 255) : subColor;

    return _HoverableNodeCard(
      enabled: !isTimeout,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: GestureDetector(
          onTap: isTimeout ? null : onTap,
          onSecondaryTapDown: onSecondaryTapDown,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: isSelected
                  ? (isDark
                      ? AppTheme.success.withValues(alpha: 15 / 255)
                      : AppTheme.success.withValues(alpha: 10 / 255))
                  : null,
              border: Border.all(
                color: isSelected
                    ? AppTheme.success.withValues(alpha: 80 / 255)
                    : isDark
                        ? AppTheme.border
                        : AppTheme.lightBorder,
                width: isSelected ? 1.5 : 1,
              ),
            ),
            child: Opacity(
              opacity: isTimeout ? 0.45 : 1.0,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    _NodeFlagBadge(
                      countryCode: countryCode,
                      selected: isSelected,
                      timeout: isTimeout,
                      isDark: isDark,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            node.name,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: isSelected
                                  ? AppTheme.success
                                  : effectiveTextColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              _TypeBadge(type: node.type, isTimeout: isTimeout),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '${node.server}:${node.port}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: effectiveSubColor,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (isTesting)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.primary,
                        ),
                      )
                    else if (isTimeout)
                      const _LatencyBadge(latency: 65535)
                    else if (latency != null && latency! > 0)
                      _LatencyBadge(latency: latency!)
                    else if (isConnected)
                      GestureDetector(
                        onTap: onTestLatency,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.primary.withValues(alpha: 15 / 255),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '测速',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppTheme.primary.withValues(
                                alpha: 200 / 255,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HoverableNodeCard extends StatefulWidget {
  const _HoverableNodeCard({required this.child, required this.enabled});

  final Widget child;
  final bool enabled;

  @override
  State<_HoverableNodeCard> createState() => _HoverableNodeCardState();
}

class _HoverableNodeCardState extends State<_HoverableNodeCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: widget.enabled ? (_) => setState(() => _hovered = true) : null,
      onExit: widget.enabled ? (_) => setState(() => _hovered = false) : null,
      child: AnimatedScale(
        scale: _hovered ? 1.006 : 1,
        duration: const Duration(milliseconds: 170),
        curve: Curves.easeOutCubic,
        child: AnimatedSlide(
          offset: _hovered ? const Offset(0, -0.018) : Offset.zero,
          duration: const Duration(milliseconds: 170),
          curve: Curves.easeOutCubic,
          child: DecoratedBox(
            decoration: BoxDecoration(
              boxShadow: [
                if (_hovered)
                  BoxShadow(
                    color: AppTheme.primary.withValues(alpha: 0.18),
                    blurRadius: 20,
                    spreadRadius: -14,
                    offset: const Offset(0, 12),
                  ),
              ],
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _NodeFlagBadge extends StatelessWidget {
  const _NodeFlagBadge({
    required this.countryCode,
    required this.selected,
    required this.timeout,
    required this.isDark,
  });

  final String countryCode;
  final bool selected;
  final bool timeout;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF080E18) : AppTheme.lightBg,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? AppTheme.success.withValues(alpha: 0.9)
                  : AppTheme.borderLight.withValues(alpha: isDark ? 0.9 : 0.45),
            ),
            boxShadow: [
              if (selected)
                BoxShadow(
                  color: AppTheme.success.withValues(alpha: 0.25),
                  blurRadius: 14,
                  spreadRadius: -8,
                ),
            ],
          ),
          child: Center(
            child: CountryFlagIcon(countryCode: countryCode, size: 24),
          ),
        ),
        if (selected)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 14,
              height: 14,
              decoration: const BoxDecoration(
                color: AppTheme.success,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_rounded,
                size: 10,
                color: Colors.white,
              ),
            ),
          ),
        if (timeout)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.28),
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.type, this.isTimeout = false});

  final String type;
  final bool isTimeout;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final display = type.toUpperCase().length > 4
        ? type.toUpperCase().substring(0, 4)
        : type.toUpperCase();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.primary.withAlpha(isTimeout ? 8 : (isDark ? 20 : 15)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        display,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: AppTheme.primary.withValues(
            alpha: (isTimeout ? 100 : 255) / 255,
          ),
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _LatencyBadge extends StatelessWidget {
  const _LatencyBadge({required this.latency});

  final int latency;

  bool get isTimeout => latency <= 0 || latency >= 65535;

  @override
  Widget build(BuildContext context) {
    final color = isTimeout
        ? AppTheme.error
        : latency < 200
            ? AppTheme.success
            : latency < 500
                ? AppTheme.warning
                : AppTheme.error;
    final text = isTimeout ? '超时' : '${latency}ms';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 15 / 255),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
