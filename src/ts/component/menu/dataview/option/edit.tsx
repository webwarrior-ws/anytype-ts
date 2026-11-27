import React, { forwardRef, useRef, useEffect, useState, useImperativeHandle } from 'react';
import { Filter, MenuItemVertical } from 'Component';
import * as I from 'Interface';

const MenuOptionEdit = forwardRef<I.MenuRef, I.Menu>((props, ref) => {
	
	const { id, param, getId, getContainer, getSize, close, setActive, onKeyDown } = props;
	const { data, className, classNameWrap } = param;
	const { option, isNew, onChange, relationKey } = data;
	const [ dummy, setDummy ] = useState(0);
	const nodeRef = useRef(null);
	const nameRef = useRef(null);
	const colorRef = useRef('');
	const n = useRef(-1);
	const keydownHandler = useRef(null);
	const isUnmountedRef = useRef(false);

	const rebind = () => {
		unbind();
		keydownHandler.current = (e: any) => onKeyDownHandler(e);
		U.Dom.addEvent(window, 'keydown', keydownHandler.current);
		window.setTimeout(() => setActive(), 15);
	};

	const unbind = () => {
		if (keydownHandler.current) {
			U.Dom.removeEvent(window, 'keydown', keydownHandler.current);
			keydownHandler.current = null;
		};
	};

	const getOptionRelationKey = (): string => {
		return option.relationKey || data.relationKey || '';
	};

	const getSections = () => {
		const colors = U.Menu.getBgColors().filter(it => it.id != 'bgColor-default');
		const children: any[] = [];

		if (!isNew && getOptionRelationKey()) {
			children.push({ id: 'objects', iconParam: { name: 'menu/action/object' }, name: translate('menuDataviewOptionEditObjects'), arrow: true });
		};

		if (isNew) {
			children.push({ id: 'create', iconParam: { name: 'menu/action/add' }, name: translate('menuDataviewOptionEditCreate') });
		} else {
			children.push({ id: 'remove', iconParam: { name: 'menu/action/remove' }, name: translate('menuDataviewOptionEditDelete') });
		};

		return [
			{ children: colors, className: 'colorPicker' },
			{ children },
		];
	};

	const getItems = () => {
		const sections = getSections();
		
		let items: any[] = [];
		for (const section of sections) {
			items = items.concat(section.children);
		};
		
		return items;
	};

	const onKeyDownHandler = (e: any) => {
		// A leaked window listener must never act for a dead menu — bail before
		// any preventDefault or it silently eats the key app-wide until restart
		if (isUnmountedRef.current) {
			return;
		};

		let ret = false;

		keyboard.shortcut('enter', e, () => {
			e.preventDefault();

			if (isNew) {
				create();
			} else {
				save();
				close();
			};

			ret = true;
		});

		if (!ret) {
			onKeyDown(e);
		};
	};

	const onKeyUp = (e: any, v: string) => {
		checkButton();
	};

	const onClick = (e: any, item: any) => {
		if (item.isBgColor) {
			colorRef.current = item.value;
			save();
			setDummy(dummy + 1);
		} else
		if (item.id == 'remove') {
			S.Popup.open('confirm', {
				data: {
					iconParam: { name: 'popup/header/confirm', color: 'orange' },
					title: translate('commonAreYouSure'),
					text: translate('popupConfirmRelationOptionRemoveText'),
					textConfirm: translate('commonDelete'),
					onConfirm: remove,
				},
			});
		} else
		if (item.id == 'create') {
			create();
		};
	};

	const onOver = (e: any, item: any) => {
		if (!item.arrow) {
			S.Menu.closeAll(J.Menu.optionEdit);
			return;
		};

		const menuParam: I.MenuParam = {
			menuKey: item.id,
			element: `#${getId()} #item-${U.Common.esc(item.id)}`,
			offsetX: getSize().width,
			vertical: I.MenuDirection.Center,
			isSub: true,
			className,
			classNameWrap,
			rebind,
			parentId: props.id,
			data: {
				label: option.name,
				type: I.NavigationType.Go,
				route: analytics.route.relation,
				filters: [
					{
						operator: I.FilterOperator.Or,
						nestedFilters: [
							{ relationKey: getOptionRelationKey(), condition: I.FilterCondition.In, value: [ option.id ] },
							{ relationKey: 'name', condition: I.FilterCondition.Equal, value: option.name },
						],
					},
				],
				skipIds: [ option.id ],
			},
		};

		const menuId = 'searchObject';

		if (!S.Menu.isOpen(menuId, item.id)) {
			S.Menu.closeAll(J.Menu.optionEdit, () => {
				S.Menu.open(menuId, menuParam);
			});
		};
	};

	const onMouseEnter = (e: any, item: any) => {
		if (!keyboard.isMouseDisabled) {
			setActive(item, false);
			onOver(e, item);
		};
	};

	const onClear = () => {
		U.Dom.addClass(U.Dom.select('#item-create', nodeRef.current), 'disabled');
	};

	const remove = () => {
		const value = Relation.getArrayValue(data.value).filter(it => it != option.id);

		C.RelationListRemoveOption([ option.id ], false);

		S.Menu.updateData(id, { value });
		S.Menu.updateData('dataviewOptionList', { value });

		onChange?.(value);
		close();
	};

	const save = () => {
		const value = String(nameRef.current?.getValue() || '');

		if (!value || isNew) {
			return;
		};

		C.ObjectListSetDetails([ option.id ], [
			{ key: 'name', value },
			{ key: 'relationOptionColor', value: getColor() },
		]);
	};

	const create = () => {
		const value = String(nameRef.current?.getValue() || '');

		if (!value) {
			return;
		};

		if (!relationKey) {
			console.error('[MenuDataviewOption.Create] No relationKey');
			return;
		};

		C.ObjectCreateRelationOption({
			relationKey,
			name: value,
			relationOptionColor: getColor(),
		}, S.Common.space, (message: any) => {
			if (message.error.code || !message.details) {
				return;
			};

			const globalSubId = U.Subscription.spaceSubId(J.Constant.subId.option);
			S.Detail.update(globalSubId, { id: message.objectId, details: message.details }, false);
		});

		close();
	};

	const getColor = () => {
		return colorRef.current;
	};
	
	const checkButton = () => {
		if (!isNew) {
			return;
		};

		const v = String(nameRef.current?.getValue() || '').trim();
		const createEl = U.Dom.select('#item-create', nodeRef.current);

		if (createEl) {
			U.Dom.toggleClass(createEl, 'disabled', !v.length);
		};
	};

	const Color = (item: any) => {
		const cn = [ 'item', 'color', `color-${item.className}` ];

		if (colorRef.current == item.value) {
			cn.push('selected');
		};

		return (
			<div
				id={`item-${item.id}`}
				className={cn.join(' ')}
				onClick={e => onClick(e, item)}
				onMouseEnter={e => onMouseEnter(e, item)}
			/>
		);
	};

	const Section = (item: any) => (
		<div className={[ 'section', (item.className ? item.className : '') ].join(' ')}>
			<div className="items">
				{item.children.map((action: any, i: number) => {
					if (action.isBgColor) {
						return <Color key={i} {...action} />;
					} else {
						return (
							<MenuItemVertical 
								key={i} 
								{...action} 
								onClick={e => onClick(e, action)}
								onMouseEnter={e => onMouseEnter(e, action)}
							/>
						);
					};
				})}
			</div>
		</div>
	);

	const sections = getSections();

	useEffect(() => {
		colorRef.current = option.color;

		rebind();
		setDummy(dummy + 1);

		return () => {
			isUnmountedRef.current = true;

			unbind();
			S.Menu.closeAll(J.Menu.optionEdit);
		};
	}, []);

	useEffect(() => {
		setActive();
		checkButton();
	});

	useImperativeHandle(ref, () => ({
		rebind,
		unbind,
		getItems,
		getIndex: () => n.current,
		setIndex: (i: number) => n.current = i,
		onClick,
		onOver,
	}), []);

	return (
		<div ref={nodeRef}>
			<Filter
				ref={nameRef}
				placeholder={isNew ? translate('menuDataviewOptionCreatePlaceholder') : translate('menuDataviewOptionEditPlaceholder')}
				value={option.name}
				onKeyUp={(e: any, v: string) => onKeyUp(e, v)}
				onClear={onClear}
				focusOnMount={true}
			/>

			{sections.map((item: any, i: number) => (
				<Section key={i} {...item} />
			))}
		</div>
	);

});

export default MenuOptionEdit;